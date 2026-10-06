# Evaluation — `shadow-w10-hc` (window)

> **STAND-IN ENCODERS — NOT INERTIA-1; real Inertia-1 evaluation blocked: no public checkpoint.** Every number below is a *measured* result for a stand-in encoder on public wrist data; nothing here is evidence about Inertia-1 itself.

- evaluated bundle_sha256 `1cd36c60fda273ab4665409428fc4b7abd2c5ac9e1b09e49ba9f12b5c81bc0b4`; sealed bundle_sha256 `e57e9f8a7c661bf2b15709d9963a316c2a90820ee066ac3a3db70cb0c2e1ee8a` (test_gate.json `ed28b0fe6e7b114d`; the served artifact carries the gate); encoder `standin:handcrafted-stats-v1` (standin); evidence_tier_max `shadow`
- provenance: git_commit `a424d207e1c44f08e267f588b2122c787336055c`, source_tree_sha256 `48a7a17c749ac61c`, source dirty False, allow_dirty False
- evaluated once on the frozen test subjects (assembled inside the TestVault) through `load_bundle(...).apply(...)`; test_sha256 `fe25fb43c8cbb546f6215785ebcb3dd25a0f117d5025a92781759edb3e1a4b2e`; evaluations of this experiment on this test split: 3 (rerun reason: post_audit_rule_change — red-team fixes G-2..G-20 (clustered strong/weak, per-dataset gate weak->abstain, compatible merges, sealing, union macro-F1); retrained from clean commit a424d207); bundle.apply vs training-side numpy max |Δ| (first 2,000 windows) 0.000000000000
- test windows: capture24 293,623 (50 subj), hhar_watch 617 (2 subj), mhealth 221 (2 subj), opportunity 245 (1 subj), pamap2 1,314 (2 subj), wisdm2019_watch 4,756 (8 subj)
- nonfinite windows dropped: 0

† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.
*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
Limitation: leave-one-subject-out folds are defined in the split manifests (`loso_folds`) for the small datasets but were NOT evaluated; every number here comes from the single frozen train/val/test split.

### posture

Posture targets: `recumbent` is mostly Capture-24 sleep-diary lying in the training data (awake lying is reported separately below); driving/passenger (vehicle) windows carry `seated_likely` because posture is genuinely labelled there; posture is MASKED on gait/cycling/exercise windows.

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 227,293 | 0.831 | 0.613 [0.600, 0.625] | 0.618 [0.601, 0.634] | 0.618 [0.601, 0.634] | 0.582→0.454 | 0.340→0.255 | 0.055→0.043 (0.003) | 0.086→0.033 | 0.083 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `seated_likely`): accuracy 0.466, balanced acc 0.333, macro-F1 0.212. Set-truth windows: 26,872; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | yes | 116,829 | 0.875 | 0.907 | 0.891 | 0.865 (107,935) | 0.052 | weak | 0.300 | P=0.875 n=121,077 → weak | hhar_watch test: precision 0.000 at n_acc 33 -> abstain | abstain | 0 |
| seated_likely | yes | 96,936 | 0.789 | 0.843 | 0.815 | 0.745 (78,958) | 0.042 | weak | 0.515 | P=0.799 n=98,292 → abstain | – | abstain | 0 |
| upright_stationary | yes | 13,528 | 0.451 | 0.088 | 0.147 | 0.499 (13,528) | 0.005 | abstain | 1.000 | – | – | abstain | 0 |
| postural_transition | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P single-label = precision (argmax) on windows whose truth is exactly one class, next to the set-target scoring (where a set-target window is correct for any member). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 225,565 | 0.607 | 0.610 [0.594, 0.627] | 0.451 | 0.044 |  |
| hhar_watch | 2 | 233 | 0.665 | 0.448 [0.394, 0.489]† | 0.919 | 0.152 | descriptive |
| mhealth | 2 | 66 | 0.439 | 0.355 [0.222, 0.475]† | 0.809 | 0.272 | descriptive |
| opportunity | 1 | 239 | 0.463 | 0.430 [0.430, 0.430]† | 1.008 | 0.206 | descriptive |
| pamap2 | 2 | 647 | 0.599 | 0.596 [0.544, 0.614]† | 0.797 | 0.099 | descriptive |
| wisdm2019_watch | 8 | 543 | 0.626 | 0.451 [0.369, 0.517]† | 0.779 | 0.085 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | 0.88/0.91/0.89 (116555); gate P 0.88 n 120573 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 33 → abstain | 0.58/1.00/0.73 (22); gate P 0.58 n 38 → abstain | 0.50/0.22/0.31 (18); gate P 0.50 n 8 → weak | 0.62/0.89/0.73 (234); gate P 0.62 n 336 → abstain | 0.00/0.00/0.00 (0); gate P 0.00 n 89 → abstain |
| seated_likely | 0.79/0.84/0.82 (96180); gate P 0.80 n 97483 → weak | 0.73/0.99/0.84 (118); gate P 0.81 n 143 → weak | 0.22/0.27/0.24 (22); gate P 0.22 n 18 → weak | 0.53/0.99/0.69 (112); gate P 0.57 n 195 → abstain | 0.48/0.42/0.45 (232); gate P 0.46 n 170 → abstain | 0.65/0.78/0.71 (272); gate P 0.72 n 283 → abstain |
| upright_stationary | 0.39/0.07/0.12 (12830) | 0.97/0.34/0.50 (115) | 1.00/0.05/0.09 (22) | 0.86/0.17/0.29 (109) | 0.81/0.49/0.61 (181) | 1.00/0.48/0.65 (271) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.

Awake lying (recumbent scored on NON-sleep windows only; G-2):

- recumbent truth windows: 134,807, of which sleep-period 107,798 (0.800) and awake lying 27,009 (by dataset: capture24 26706, hhar_watch 0, mhealth 22, opportunity 18, pamap2 263, wisdm2019_watch 0)
- recumbent on non-sleep windows: P 0.373, R 0.995, F1 0.542 (support 9,031, predicted 24,111)
- awake-lying gate at the frozen tau: pooled P=0.373 n=24,111 → abstain; per dataset capture24 P=0.371 n=23,607 → abstain, hhar_watch P=0.000 n=33 → abstain, mhealth P=0.579 n=38 → abstain, opportunity P=0.500 n=8 → weak, pamap2 P=0.619 n=336 → abstain, wisdm2019_watch P=0.000 n=89 → abstain; awake-lying status abstain (reported only; the served recumbent status is the pooled one)


Wrist-only: n=227,293, macro-F1 0.618 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.975, P 0.838; ≥0.6: cov 0.866, P 0.866; ≥0.7: cov 0.731, P 0.891; ≥0.8: cov 0.544, P 0.919; ≥0.9: cov 0.270, P 0.947; ≥0.95: cov 0.104, P 0.963

Confusion (rows truth, cols pred; recumbent, seated_likely, upright_stationary, postural_transition):

```
 105954   10803      72       0
  13835   81725    1376       0
   1288   11051    1189       0
      0       0       0       0
```

### locomotion

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 282,152 | 0.855 | 0.589 [0.560, 0.619] | 0.616 [0.583, 0.641] | 0.616 [0.583, 0.641] | 0.715→0.434 | 0.369→0.205 | 0.063→0.021 (0.002) | 0.078→0.011 | 0.033 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `stationary`): accuracy 0.795, balanced acc 0.143, macro-F1 0.127. Set-truth windows: 1,438; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| stationary | yes | 223,808 | 0.884 | 0.977 | 0.928 | 0.884 (222,969) | 0.023 | strong | 0.875 | P=0.975 n=174,862 → strong | pamap2 test: precision 0.901 at n_acc 425 -> weak | weak | 0 |
| walking | yes | 27,293 | 0.782 | 0.506 | 0.614 | 0.775 (26,694) | 0.014 | strong | 0.850 | P=0.975 n=7,813 → strong | – | strong | 0 |
| brisk_walking | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| running | yes | 669 | 0.877 | 0.867 | 0.872 | 0.877 (669) | 0.001 | strong | 0.965 | P=0.962 n=339 → strong | capture24 test: precision 0.897 at n_acc 126 -> weak | weak | 0 |
| stairs | yes | 591 | 0.543 | 0.658 | 0.595 | 0.546 (591) | 0.002 | weak | 0.590 | P=0.754 n=398 → abstain | – | abstain | 0 |
| cycling | yes | 2,536 | 0.627 | 0.618 | 0.623 | 0.627 (2,536) | 0.003 | weak | 0.585 | P=0.742 n=1,889 → abstain | – | abstain | 0 |
| vehicle_motion | yes | 10,735 | 0.754 | 0.316 | 0.445 | 0.755 (10,735) | 0.025 | abstain | 1.000 | – | – | abstain | 0 |
| other | yes | 16,520 | 0.336 | 0.181 | 0.235 | 0.341 (16,520) | 0.010 | abstain | 1.000 | – | – | abstain | 0 |

P single-label = precision (argmax) on windows whose truth is exactly one class, next to the set-target scoring (where a set-target window is correct for any member). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 275,781 | 0.499 | 0.516 [0.396, 0.542] | 0.437 | 0.022 |  |
| hhar_watch | 2 | 617 | 0.936 | 0.748 [0.742, 0.937]† | 0.239 | 0.100 | descriptive |
| mhealth | 2 | 221 | 0.880 | 0.873 [0.817, 0.948]† | 0.248 | 0.071 | descriptive |
| opportunity | 1 | 245 | 0.721 | 0.367 [0.367, 0.367]† | 0.416 | 0.196 | descriptive |
| pamap2 | 2 | 1,314 | 0.752 | 0.748 [0.724, 0.749]† | 0.578 | 0.049 | descriptive |
| wisdm2019_watch | 8 | 3,974 | 0.849 | 0.491 [0.458, 0.587]† | 0.217 | 0.072 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|
| stationary | 0.88/0.98/0.93 (219468); gate P 0.97 n 171648 → strong | 0.99/1.00/0.99 (233); gate P 1.00 n 194 → strong | 1.00/0.92/0.96 (83); gate P 1.00 n 66 → strong | 1.00/0.94/0.97 (239); gate P 1.00 n 73 → strong | 0.80/0.90/0.85 (593); gate P 0.90 n 425 → weak | 0.99/0.98/0.99 (3192); gate P 1.00 n 2456 → strong |
| walking | 0.78/0.50/0.61 (26752); gate P 0.97 n 7402 → strong | 0.79/1.00/0.88 (114); gate P 1.00 n 96 → strong | 0.68/1.00/0.81 (21); gate P 1.00 n 20 → weak | 0.50/0.50/0.50 (6) | 0.78/0.96/0.86 (162); gate P 1.00 n 98 → strong | 0.67/0.92/0.78 (238); gate P 0.97 n 197 → strong |
| running | 0.76/0.80/0.78 (319); gate P 0.90 n 126 → weak | 0.00/0.00/0.00 (0) | 0.95/1.00/0.98 (41); gate P 1.00 n 21 → weak | 0.00/0.00/0.00 (0) | 1.00/0.97/0.99 (37); gate P 1.00 n 36 → strong | 1.00/0.91/0.95 (272); gate P 1.00 n 156 → strong |
| stairs | 0.01/0.14/0.02 (29); gate P 0.04 n 100 → abstain | 1.00/0.87/0.93 (163); gate P 1.00 n 113 → strong | 1.00/0.47/0.64 (15); gate P 1.00 n 3 → weak | 0.00/0.00/0.00 (0) | 0.94/0.71/0.81 (112); gate P 1.00 n 60 → strong | 0.95/0.58/0.72 (272); gate P 0.98 n 122 → strong |
| cycling | 0.60/0.59/0.60 (2317); gate P 0.72 n 1684 → abstain | 1.00/0.88/0.94 (107); gate P 1.00 n 94 → strong | 1.00/1.00/1.00 (22); gate P 1.00 n 22 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 1 → weak | 1.00/0.87/0.93 (90); gate P 1.00 n 74 → strong | 0.00/0.00/0.00 (0); gate P 0.00 n 14 → weak |
| vehicle_motion | 0.75/0.32/0.45 (10628) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (107) | 0.00/0.00/0.00 (0) |
| other | 0.32/0.17/0.22 (16268) | 0.00/0.00/0.00 (0) | 0.83/0.90/0.86 (39) | 0.00/0.00/0.00 (0) | 0.76/0.85/0.80 (213) | 0.00/0.00/0.00 (0) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=282,152, macro-F1 0.616 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.900, P 0.906; ≥0.6: cov 0.849, P 0.929; ≥0.7: cov 0.799, P 0.948; ≥0.8: cov 0.739, P 0.964; ≥0.9: cov 0.596, P 0.978; ≥0.95: cov 0.401, P 0.985

Confusion (rows truth, cols pred; stationary, walking, brisk_walking, running, stairs, cycling, vehicle_motion, other):

```
 218550    1816       0      18      54     415     610    2345
   9700   13805       0      19     166     291     239    3073
      0       0       0       0       0       0       0       0
     27      52       0     580       6       0       0       4
     22     156       0       0     389       0       1      23
    742     113       0       3       0    1567       6     105
   6659     283       0       1      15      24    3388     365
  11523    1431       0      40      87     201     251    2987
```

### arm_behavior

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 64,906 | 0.641 | 0.443 [0.404, 0.552] | 0.430 [0.379, 0.498] | 0.430 [0.379, 0.498] | 0.936→0.708 | 0.594→0.466 | 0.118→0.069 (0.005) | 0.183→0.052 | 0.274 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `desk_like`): accuracy 0.640, balanced acc 0.333, macro-F1 0.260. Set-truth windows: 0; windows whose truth is an unsupported class (not scored): 62.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| quiet | yes | 21,537 | 0.410 | 0.068 | 0.116 | 0.410 (21,537) | 0.074 | abstain | 1.000 | – | – | abstain | 0 |
| desk_like | yes | 41,544 | 0.656 | 0.952 | 0.777 | 0.656 (41,544) | 0.072 | weak | 0.715 | P=0.724 n=35,582 → abstain | – | abstain | 0 |
| fidgeting | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| repetitive_hand_motion | yes | 1,825 | 0.546 | 0.311 | 0.396 | 0.546 (1,825) | 0.011 | strong | 0.960 | P=0.829 n=193 → weak | capture24 test: precision 0.029 at n_acc 34 -> abstain | abstain | 0 |
| active_gesturing | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| exercise_motion | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 62 |
| other | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P single-label = precision (argmax) on windows whose truth is exactly one class, next to the set-target scoring (where a set-target window is correct for any member). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 63,583 | 0.369 | 0.337 [0.289, 0.368] | 0.709 | 0.070 |  |
| mhealth | 2 | 44 | 0.000 | 0.000 [0.000, 0.000]† | 1.397 | 0.745 | descriptive |
| pamap2 | 2 | 191 | 0.351 | 0.275 [0.234, 0.310]† | 1.170 | 0.398 | descriptive |
| wisdm2019_watch | 8 | 1,088 | 0.865 | 0.577 [0.473, 0.657]† | 0.529 | 0.122 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | mhealth | pamap2 | wisdm2019_watch |
|---|---|---|---|---|
| quiet | 0.41/0.07/0.12 (21396) | 0.00/0.00/0.00 (44) | 0.00/0.00/0.00 (97) | 0.00/0.00/0.00 (0) |
| desk_like | 0.66/0.95/0.78 (41000); gate P 0.72 n 34912 → abstain | 0.00/0.00/0.00 (0); gate P 0.00 n 40 → abstain | 0.00/0.00/0.00 (0); gate P 0.00 n 73 → abstain | 0.79/1.00/0.88 (544); gate P 0.96 n 557 → strong |
| repetitive_hand_motion | 0.18/0.09/0.12 (1187); gate P 0.03 n 34 → abstain | 0.00/0.00/0.00 (0) | 1.00/0.70/0.82 (94) | 1.00/0.73/0.85 (544); gate P 1.00 n 159 → strong |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=64,906, macro-F1 0.430 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.952, P 0.651; ≥0.6: cov 0.826, P 0.671; ≥0.7: cov 0.606, P 0.713; ≥0.8: cov 0.192, P 0.771; ≥0.9: cov 0.016, P 0.776; ≥0.95: cov 0.005, P 0.804

Confusion (rows truth, cols pred; quiet, desk_like, fidgeting, repetitive_hand_motion, active_gesturing, exercise_motion, other):

```
   1462   19823       0     252       0       0       0
   1779   39545       0     220       0       0       0
      0       0       0       0       0       0       0
    327     931       0     567       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
```

### movement_intensity

Target clip(ln(MET)/ln(12),0,1) from Capture-24 annotation METs / PAMAP2 protocol METs; split-conformal 80% half-width 0.157.

| set | n | MAE | MAE const (test mean) | R² | Spearman | 80% interval coverage |
|---|---|---|---|---|---|---|
| pooled | 294,418 | 0.113 | 0.136 | 0.405 | 0.749 | 0.772 |
| capture24 | 293,623 | 0.113 | 0.136 | 0.400 | 0.748 | 0.772 |
| pamap2 | 795 | 0.111 | 0.202 | 0.641 | 0.819 | 0.706 |

## OOD

Bundle method `maha_global` (k=None), threshold 14.207 (0.95 quantile of VAL ID scores); ID test false-alarm rate 0.046 on 299,994 windows.


Measured: every table above (test subjects, once). Inferred: nothing about Inertia-1 or WHOOP straps — the encoders are stand-ins and the data are public wrist datasets.
