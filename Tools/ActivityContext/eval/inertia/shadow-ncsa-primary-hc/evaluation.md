# Evaluation — `shadow-ncsa-primary-hc` (primary)

> **STAND-IN ENCODERS — NOT INERTIA-1; real Inertia-1 evaluation blocked: no public checkpoint.** Every number below is a *measured* result for a stand-in encoder on public wrist data; nothing here is evidence about Inertia-1 itself.

- evaluated bundle_sha256 `e80ec473385d59870a83d9dac479371ce34911cb85463a9b78237af6e03f34e6`; sealed bundle_sha256 `898d9810f6ac84facaa1b7751e3452502f049d22537cc4e12ee474234612d3cc` (test_gate.json `1bb4064c3d80430a`; the served artifact carries the gate); encoder `standin:handcrafted-stats-v1` (standin); evidence_tier_max `shadow`
- provenance: git_commit `744e33a76ae52a758d82c6f8dd1440dbf24b913d`, source_tree_sha256 `443e2fe493e33691`, source dirty False, allow_dirty False
- evaluated once on the frozen test subjects (assembled inside the TestVault) through `load_bundle(...).apply(...)`; test_sha256 `c805f429821bb80c15da4ee6b2066c593321a40b3df8a0d7d26b01a838c5d7b1`; evaluations of this experiment on this test split: 2 (rerun reason: post_audit_rule_change — audit G2 D-1 (2026-10-06): set-target status rule set-family-1 - VAL operating points, statuses, tau and the pooled and per-dataset test gates of a set member use only windows unambiguous for it (a set window {walking, brisk_walking} / {recumbent, seated_likely} / {walking, brisk_walking, stationary} no longer counts as correct for whichever member is predicted); set families are scored as one class (reported only); locomotion merges are directed specific->general (brisk_walking->walking, stairs->walking). Bundle retrained from clean commit 744e33a7: heads, calibration and OOD reference identical to the previously sealed bundle; statuses, tau, merges, families and provenance change. Ledger entries now also record per-dataset test-split reuse (G2 D-2).); bundle.apply vs training-side numpy max |Δ| (first 2,000 windows) 0.000000000000
- test windows: capture24 96,819 (50 subj), gotov 587 (7 subj), hhar_watch 1,998 (2 subj), mhealth 49 (2 subj), opportunity 2,539 (1 subj), pamap2 5,167 (2 subj), wear 319 (5 subj), wisdm2019_watch 1,397 (8 subj)
- nonfinite windows dropped: 0
- evaluations of each dataset's test split (any experiment, this one included; G2 D-2): capture24 78, gotov 13, hhar_watch 78, mhealth 78, opportunity 78, pamap2 78, wear 13, wisdm2019_watch 78

† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.
*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
Limitation: leave-one-subject-out folds are defined in the split manifests (`loso_folds`) for the small datasets but were NOT evaluated; every number here comes from the single frozen train/val/test split.

### posture

Posture targets: `recumbent` is mostly Capture-24 sleep-diary lying in the training data (awake lying is reported separately below); driving/passenger (vehicle) windows carry `seated_likely` because posture is genuinely labelled there; posture is MASKED on gait/cycling/exercise windows.

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 74,861 | 0.858 | 0.645 [0.631, 0.662] | 0.658 [0.639, 0.676] | 0.658 [0.639, 0.676] | 0.501→0.384 | 0.288→0.214 | 0.018→0.021 (0.004) | 0.089→0.024 | 0.062 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `recumbent`): accuracy 0.597, balanced acc 0.333, macro-F1 0.249. Set-truth windows: 8,630; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | yes | 38,376 | 0.911 | 0.920 | 0.915 | 0.905 (36,065) | 0.032 | weak | 0.300 | P=0.905 n=36,443 → weak | gotov test: precision 0.627 at n_acc 158 -> abstain | abstain | 0 |
| seated_likely | yes | 32,187 | 0.812 | 0.880 | 0.845 | 0.771 (25,868) | 0.032 | weak | 0.300 | P=0.771 n=28,694 → abstain | – | abstain | 0 |
| upright_stationary | yes | 4,298 | 0.484 | 0.137 | 0.213 | 0.537 (4,298) | 0.006 | abstain | 1.000 | – | – | abstain | 0 |
| postural_transition | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P/R/F1 = set-target scoring (a set-target window is correct for any member); P single-label = precision (argmax) on windows whose truth is exactly one class. Statuses, tau and every gate use the `set-family-1` rule: a set member is judged on its single-label evidence only (windows whose truth is a set containing it are excluded). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Set families (each scored as ONE class: merged probability, correct iff the truth lies inside the family; reported only — a family status never changes a served per-class status):

| family | test windows with exactly this set | argmax P / R (n_acc) | val status | tau | pooled gate | dataset demotions | final family status |
|---|---|---|---|---|---|---|---|
| recumbent+seated_likely | 8,630 | 0.949 / 0.992 (73,783) | strong | 0.695 | P=0.960 n=71,466 → strong | hhar_watch test: precision 0.621 at n_acc 58 -> abstain | abstain |

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 73,985 | 0.638 | 0.647 [0.630, 0.665] | 0.381 | 0.023 |  |
| gotov | 7 | 386 | 0.671 | 0.691 [0.577, 0.786]† | 0.583 | 0.108 |  |
| hhar_watch | 2 | 74 | 0.284 | 0.273 [0.190, 0.325]† | 1.436 | 0.362 | descriptive |
| mhealth | 2 | 16 | 0.389 | 0.262 [0.167, 0.333]† | 0.936 | 0.394 | descriptive |
| opportunity | 1 | 37 | 0.571 | 0.580 [0.580, 0.580]† | 0.487 | 0.116 | descriptive |
| pamap2 | 2 | 204 | 0.737 | 0.742 [0.707, 0.742]† | 0.556 | 0.084 | descriptive |
| wisdm2019_watch | 8 | 159 | 0.685 | 0.487 [0.374, 0.565]† | 0.739 | 0.125 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | gotov | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | 0.91/0.92/0.92 (38178); gate P 0.91 n 36183 → weak | 0.63/0.79/0.70 (126); gate P 0.63 n 158 → abstain | 0.00/0.00/0.00 (0); gate P 0.00 n 45 → abstain | 0.33/1.00/0.50 (4); gate P 0.33 n 12 → weak | 0.00/0.00/0.00 (0) | 0.90/0.82/0.86 (68); gate P 0.76 n 25 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 20 → weak |
| seated_likely | 0.81/0.88/0.85 (31771); gate P 0.77 n 28288 → abstain | 0.67/0.68/0.67 (182); gate P 0.67 n 184 → abstain | 0.59/0.27/0.37 (37); gate P 0.59 n 17 → weak | 0.00/0.00/0.00 (6); gate P 0.00 n 3 → weak | 0.83/1.00/0.91 (30); gate P 0.83 n 36 → weak | 0.66/0.72/0.69 (81); gate P 0.58 n 72 → abstain | 0.68/0.80/0.74 (80); gate P 0.68 n 94 → abstain |
| upright_stationary | 0.43/0.11/0.18 (4036) | 0.98/0.55/0.70 (78) | 0.92/0.30/0.45 (37) | 1.00/0.17/0.29 (6) | 1.00/0.14/0.25 (7) | 0.69/0.67/0.68 (55) | 1.00/0.57/0.73 (79) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.

Awake lying (recumbent scored on NON-sleep windows only; G-2):

- recumbent truth windows: 44,695, of which sleep-period 35,904 (0.803) and awake lying 8,791 (by dataset: capture24 8576, gotov 126, hhar_watch 0, mhealth 4, opportunity 0, pamap2 85, wisdm2019_watch 0)
- recumbent on non-sleep windows: P 0.412, R 0.983, F1 0.581 (support 2,472, predicted 5,892)
- awake-lying gate at the frozen tau: pooled P=0.034 n=3,584 → abstain; per dataset capture24 P=0.000 n=3,324 → abstain, gotov P=0.627 n=158 → abstain, hhar_watch P=0.000 n=45 → abstain, mhealth P=0.333 n=12 → weak, pamap2 P=0.760 n=25 → weak, wisdm2019_watch P=0.000 n=20 → weak; awake-lying status abstain (reported only; the served recumbent status is the pooled one)


Wrist-only: n=74,861, macro-F1 0.658 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.987, P 0.861; ≥0.6: cov 0.913, P 0.881; ≥0.7: cov 0.823, P 0.903; ≥0.8: cov 0.687, P 0.927; ≥0.9: cov 0.436, P 0.953; ≥0.95: cov 0.216, P 0.968

Confusion (rows truth, cols pred; recumbent, seated_likely, upright_stationary, postural_transition):

```
  35289    3050      37       0
   3263   28335     589       0
    199    3512     587       0
      0       0       0       0
```

### locomotion

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 92,557 | 0.867 | 0.664 [0.631, 0.703] | 0.693 [0.668, 0.721] | 0.693 [0.668, 0.721] | 0.500→0.368 | 0.240→0.177 | 0.051→0.017 (0.004) | 0.040→0.009 | 0.024 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `stationary`): accuracy 0.799, balanced acc 0.125, macro-F1 0.111. Set-truth windows: 8,759; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| stationary | yes | 73,706 | 0.908 | 0.969 | 0.938 | 0.933 (73,462) | 0.019 | strong | 0.785 | P=0.974 n=65,752 → strong | pamap2 test: precision 0.918 at n_acc 158 -> weak | weak | 0 |
| walking | yes | 5,613 | 0.758 | 0.351 | 0.480 | 0.050 (33) | 0.015 | weak | 0.840 | P=0.586 n=29 → weak | – | weak | 0 |
| brisk_walking | yes | 2,954 | 0.920 | 0.818 | 0.866 | 0.000 (19) | 0.008 | abstain | 1.000 | – | – | abstain | 0 |
| running | yes | 296 | 0.894 | 0.851 | 0.872 | 0.947 (296) | 0.001 | strong | 0.920 | P=0.930 n=229 → weak | – | weak | 0 |
| stairs | yes | 152 | 0.699 | 0.842 | 0.764 | 0.889 (152) | 0.001 | strong | 0.825 | P=0.955 n=88 → weak | – | weak | 0 |
| cycling | yes | 855 | 0.749 | 0.695 | 0.721 | 0.865 (855) | 0.002 | strong | 0.930 | P=0.934 n=361 → weak | – | weak | 0 |
| vehicle_motion | yes | 3,518 | 0.724 | 0.429 | 0.539 | 0.758 (3,518) | 0.020 | weak | 0.535 | P=0.852 n=1,516 → weak | – | weak | 0 |
| other | yes | 5,463 | 0.372 | 0.360 | 0.366 | 0.566 (5,463) | 0.009 | abstain | 1.000 | – | – | abstain | 0 |

P/R/F1 = set-target scoring (a set-target window is correct for any member); P single-label = precision (argmax) on windows whose truth is exactly one class. Statuses, tau and every gate use the `set-family-1` rule: a set member is judged on its single-label evidence only (windows whose truth is a set containing it are excluded). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Set families (each scored as ONE class: merged probability, correct iff the truth lies inside the family; reported only — a family status never changes a served per-class status):

| family | test windows with exactly this set | argmax P / R (n_acc) | val status | tau | pooled gate | dataset demotions | final family status |
|---|---|---|---|---|---|---|---|
| walking+brisk_walking | 8,306 | 0.794 / 0.546 (5,748) | strong | 0.835 | P=0.974 n=2,951 → strong | – | strong |
| stationary+walking+brisk_walking | 453 | 0.925 / 0.976 (86,896) | strong | 0.820 | P=0.980 n=69,960 → strong | pamap2 test: precision 0.937 at n_acc 175 -> weak | weak |

Rule change (G2 D-1): the earlier set-target scoring on the same bundle and test windows vs the single-label rule:

| class | test set windows excluded | set-target val→final (tau) | single-label val→final (tau) |
|---|---|---|---|
| walking | 8,759 | abstain→abstain (1.000) | weak→weak (0.840) |
| brisk_walking | 8,759 | strong→strong (0.805) | abstain→abstain (1.000) |

merge_into under the old rule (symmetric table): {'walking': 'brisk_walking'}

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 89,829 | 0.552 | 0.577 [0.480, 0.615] | 0.372 | 0.017 |  |
| gotov | 7 | 585 | 0.758 | 0.714 [0.682, 0.968]† | 0.230 | 0.062 |  |
| hhar_watch | 2 | 174 | 0.970 | 0.780 [0.756, 1.000]† | 0.164 | 0.105 | descriptive |
| mhealth | 2 | 49 | 0.991 | 0.987 [0.966, 1.000]† | 0.142 | 0.067 | descriptive |
| opportunity | 1 | 37 | 1.000 | 1.000 [1.000, 1.000]† | 0.259 | 0.212 | descriptive |
| pamap2 | 2 | 397 | 0.755 | 0.729 [0.700, 0.740]† | 0.561 | 0.067 | descriptive |
| wear | 5 | 319 | 0.880 | 0.536 [0.515, 0.679]† | 0.332 | 0.055 |  |
| wisdm2019_watch | 8 | 1,167 | 0.931 | 0.541 [0.512, 0.792]† | 0.143 | 0.079 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | gotov | hhar_watch | mhealth | opportunity | pamap2 | wear | wisdm2019_watch |
|---|---|---|---|---|---|---|---|---|
| stationary | 0.91/0.97/0.94 (71954); gate P 0.97 n 64290 → strong | 0.96/0.96/0.96 (386); gate P 1.00 n 327 → strong | 0.99/1.00/0.99 (74); gate P 1.00 n 67 → strong | 1.00/0.95/0.97 (19); gate P 1.00 n 16 → weak | 1.00/1.00/1.00 (37); gate P 1.00 n 23 → weak | 0.83/0.90/0.87 (187); gate P 0.92 n 158 → weak | 0.81/0.91/0.86 (112); gate P 0.93 n 74 → weak | 1.00/0.99/0.99 (937); gate P 1.00 n 797 → strong |
| walking | 0.76/0.35/0.48 (5578); gate P 0.00 n 12 → weak | 0.63/1.00/0.78 (33); gate P 1.00 n 17 → weak | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 1.00/0.50/0.67 (2) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) |
| brisk_walking | 0.92/0.82/0.87 (2785) | 0.00/0.00/0.00 (19) | 0.95/1.00/0.97 (35) | 1.00/1.00/1.00 (4) | 0.00/0.00/0.00 (0) | 0.97/0.73/0.83 (41) | 0.00/0.00/0.00 (0) | 0.88/0.96/0.92 (70) |
| running | 0.84/0.61/0.71 (103); gate P 0.93 n 57 → weak | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 1.00/1.00/1.00 (10); gate P 1.00 n 7 → weak | 0.00/0.00/0.00 (0) | 0.36/1.00/0.53 (10); gate P 0.45 n 22 → weak | 1.00/0.96/0.98 (93); gate P 1.00 n 83 → strong | 1.00/1.00/1.00 (80); gate P 1.00 n 60 → strong |
| stairs | 0.04/0.25/0.06 (8); gate P 0.00 n 4 → weak | 0.00/0.00/0.00 (0) | 1.00/1.00/1.00 (32); gate P 1.00 n 22 → weak | 1.00/1.00/1.00 (3) | 0.00/0.00/0.00 (0) | 1.00/1.00/1.00 (29); gate P 1.00 n 17 → weak | 0.00/0.00/0.00 (0) | 1.00/0.78/0.87 (80); gate P 1.00 n 45 → strong |
| cycling | 0.71/0.66/0.68 (743); gate P 0.92 n 285 → weak | 1.00/1.00/1.00 (47); gate P 1.00 n 46 → strong | 1.00/0.88/0.94 (33); gate P 1.00 n 12 → weak | 1.00/1.00/1.00 (4); gate P 1.00 n 2 → weak | 0.00/0.00/0.00 (0) | 1.00/0.96/0.98 (28); gate P 1.00 n 16 → weak | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) |
| vehicle_motion | 0.73/0.43/0.54 (3484); gate P 0.85 n 1514 → weak | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.75/0.09/0.16 (34); gate P 1.00 n 2 → weak | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) |
| other | 0.35/0.33/0.34 (5174) | 0.84/0.83/0.83 (100) | 0.00/0.00/0.00 (0) | 0.90/1.00/0.95 (9) | 0.00/0.00/0.00 (0) | 0.76/0.85/0.80 (66) | 0.94/0.77/0.85 (114) | 0.00/0.00/0.00 (0) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=92,557, macro-F1 0.693 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.899, P 0.919; ≥0.6: cov 0.845, P 0.943; ≥0.7: cov 0.799, P 0.960; ≥0.8: cov 0.745, P 0.974; ≥0.9: cov 0.648, P 0.986; ≥0.95: cov 0.532, P 0.992

Confusion (rows truth, cols pred; stationary, walking, brisk_walking, running, stairs, cycling, vehicle_motion, other):

```
  71446     380      74       4       5      53     375    1369
   1921    1972       0       0      15      14      65    1626
    235      19    2415      16      24      92      23     130
      4       3      34     252       0       0       0       3
      3       2       9       0     128       0       0      10
    205       7      16       0       0     594       3      30
   1805      21      29       0       1       3    1510     149
   3086     196      48      10      10      37     109    1967
```

### arm_behavior

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 21,113 | 0.662 | 0.592 [0.546, 0.686] | 0.543 [0.504, 0.599] | 0.543 [0.504, 0.599] | 0.776→0.648 | 0.494→0.424 | 0.074→0.067 (0.010) | 0.097→0.041 | 0.201 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `desk_like`): accuracy 0.645, balanced acc 0.250, macro-F1 0.196. Set-truth windows: 0; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| quiet | yes | 6,845 | 0.630 | 0.031 | 0.059 | 0.630 (6,845) | 0.081 | abstain | 1.000 | – | – | abstain | 0 |
| desk_like | yes | 13,608 | 0.663 | 0.986 | 0.793 | 0.663 (13,608) | 0.070 | weak | 0.715 | P=0.777 n=11,931 → abstain | – | abstain | 0 |
| fidgeting | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| repetitive_hand_motion | yes | 582 | 0.638 | 0.491 | 0.555 | 0.638 (582) | 0.007 | strong | 0.730 | P=0.903 n=185 → weak | capture24 test: precision 0.500 at n_acc 36 -> abstain | abstain | 0 |
| active_gesturing | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| exercise_motion | yes | 78 | 0.691 | 0.859 | 0.766 | 0.691 (78) | 0.006 | strong | 0.815 | P=0.964 n=56 → weak | – | weak | 0 |
| other | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P/R/F1 = set-target scoring (a set-target window is correct for any member); P single-label = precision (argmax) on windows whose truth is exactly one class. Statuses, tau and every gate use the `set-family-1` rule: a set member is judged on its single-label evidence only (windows whose truth is a set containing it are excluded). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 20,580 | 0.444 | 0.304 [0.218, 0.354] | 0.655 | 0.069 |  |
| gotov | 7 | 63 | 1.000 | 1.000 [1.000, 1.000]† | 0.139 | 0.130 |  |
| mhealth | 2 | 19 | 0.500 | 0.333 [0.333, 0.333]† | 0.737 | 0.456 | descriptive |
| pamap2 | 2 | 67 | 0.667 | 0.500 [0.333, 0.500]† | 0.694 | 0.348 | descriptive |
| wear | 5 | 64 | 0.828 | 0.453 [0.416, 0.492]† | 0.377 | 0.097 |  |
| wisdm2019_watch | 8 | 320 | 0.916 | 0.915 [0.755, 1.000]† | 0.307 | 0.120 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | gotov | mhealth | pamap2 | wear | wisdm2019_watch |
|---|---|---|---|---|---|---|
| quiet | 0.63/0.03/0.06 (6802) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (12) | 0.00/0.00/0.00 (31) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) |
| desk_like | 0.66/0.99/0.79 (13385); gate P 0.77 n 11708 → abstain | 1.00/1.00/1.00 (63); gate P 1.00 n 63 → strong | 0.00/0.00/0.00 (0); gate P 0.00 n 1 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 18 → weak | 0.00/0.00/0.00 (0) | 0.86/1.00/0.92 (160); gate P 0.99 n 141 → strong |
| repetitive_hand_motion | 0.43/0.32/0.37 (393); gate P 0.50 n 36 → abstain | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 1.00/1.00/1.00 (29); gate P 1.00 n 29 → weak | 0.00/0.00/0.00 (0) | 1.00/0.83/0.91 (160); gate P 1.00 n 120 → strong |
| exercise_motion | 0.00/0.00/0.00 (0); gate P 0.00 n 2 → weak | 0.00/0.00/0.00 (0) | 1.00/1.00/1.00 (7); gate P 1.00 n 7 → weak | 1.00/1.00/1.00 (7); gate P 1.00 n 3 → weak | 1.00/0.83/0.91 (64); gate P 1.00 n 44 → strong | 0.00/0.00/0.00 (0) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=21,113, macro-F1 0.543 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.963, P 0.671; ≥0.6: cov 0.847, P 0.705; ≥0.7: cov 0.623, P 0.769; ≥0.8: cov 0.304, P 0.850; ≥0.9: cov 0.054, P 0.923; ≥0.95: cov 0.007, P 0.957

Confusion (rows truth, cols pred; quiet, desk_like, fidgeting, repetitive_hand_motion, active_gesturing, exercise_motion, other):

```
    213    6519       0      99       0      14       0
    114   13415       0      63       0      16       0
      0       0       0       0       0       0       0
     11     285       0     286       0       0       0
      0       0       0       0       0       0       0
      0      11       0       0       0      67       0
      0       0       0       0       0       0       0
```

### transition (multi-label events)

| event | supported | n (pos) | AUROC | AP | Brier raw→cal | ECE raw→cal | val→final status |
|---|---|---|---|---|---|---|---|
| sit_to_stand_like | yes | 75,597 (385) | 0.928 | 0.062 | 0.092→0.090 | 0.211→0.191 | abstain→abstain |
| stand_to_sit_like | yes | 75,597 (518) | 0.898 | 0.053 | 0.096→0.095 | 0.213→0.190 | abstain→abstain |
| lying_down_like | no | – (0) | – | – | – | – | unsupported |
| getting_up_like | no | – (11) | – | – | – | – | unsupported |
| walk_start | yes | 75,597 (492) | 0.926 | 0.090 | 0.091→0.088 | 0.208→0.185 | abstain→abstain |
| walk_stop | yes | 75,597 (650) | 0.906 | 0.077 | 0.101→0.100 | 0.221→0.202 | abstain→abstain |
| run_start | no | – (4) | – | – | – | – | unsupported |
| run_stop | no | – (0) | – | – | – | – | unsupported |

Event-level (Opportunity/PAMAP2/HHAR dense 2-s windows; theta chosen on val):

| event | theta (val status) | true events | P/R/F1 ±5 s | P/R/F1 ±10 s | median / p90 abs error (s, ±10 s) |
|---|---|---|---|---|---|
| sit_to_stand_like | 0.85 (weak) | 36 | 0.18/0.53/0.27 | 0.20/0.58/0.30 | 2.7 / 4.3 |
| stand_to_sit_like | 0.95 (weak) | 36 | 0.00/0.00/0.00 | 0.00/0.00/0.00 | – / – |
| walk_start | 0.65 (weak) | 405 | 0.43/0.40/0.42 | 0.52/0.48/0.50 | 2.5 / 6.1 |
| walk_stop | 0.65 (weak) | 404 | 0.49/0.36/0.41 | 0.60/0.44/0.51 | 2.5 / 7.0 |

event-level timing only where ground truth supports it (Opportunity, PAMAP2, HHAR dense 2-s windows); Capture-24 supports event presence only (per-window AUROC/AP above)

### movement_intensity

Target clip(ln(MET)/ln(12),0,1) from Capture-24 annotation METs / PAMAP2 protocol METs / GOTOV measured COSMED METs per window (gotov-met-1); split-conformal 80% half-width 0.130.

| set | n | MAE | MAE const (test mean) | R² | Spearman | 80% interval coverage |
|---|---|---|---|---|---|---|
| pooled | 96,146 | 0.095 | 0.137 | 0.558 | 0.787 | 0.772 |
| capture24 | 95,579 | 0.095 | 0.136 | 0.553 | 0.786 | 0.773 |
| gotov | 333 | 0.103 | 0.206 | 0.691 | 0.802 | 0.679 |
| pamap2 | 234 | 0.105 | 0.203 | 0.636 | 0.855 | 0.744 |

## OOD

Bundle method `maha_global` (k=None), threshold 14.419 (0.95 quantile of VAL ID scores); ID test false-alarm rate 0.046 on 98,307 windows.


Measured: every table above (test subjects, once). Inferred: nothing about Inertia-1 or WHOOP straps — the encoders are stand-ins and the data are public wrist datasets.
