# Evaluation — `shadow-mlp-art` (arch)

> **STAND-IN ENCODERS — NOT INERTIA-1; real Inertia-1 evaluation blocked: no public checkpoint.** Every number below is a *measured* result for a stand-in encoder on public wrist data; nothing here is evidence about Inertia-1 itself.

- evaluated bundle_sha256 `885c8abdcbd432dd1b557c7bbccbc21acff23be35120e642213745c6d92518ce`; sealed bundle_sha256 `9e92482d60c2a4bf89c12afe2ce80f33739698c74f23476926111242360e6008` (test_gate.json `520d29b2e26bcb1f`; the served artifact carries the gate); encoder `standin:inertia-arch-random-init/ar_transformer-small/seed0` (standin); evidence_tier_max `shadow`
- provenance: git_commit `744e33a76ae52a758d82c6f8dd1440dbf24b913d`, source_tree_sha256 `443e2fe493e33691`, source dirty False, allow_dirty False
- evaluated once on the frozen test subjects (assembled inside the TestVault) through `load_bundle(...).apply(...)`; test_sha256 `6afd705530ea8f98e32f7c40997c4db53952ebdcd411fea823493c71a8311898`; evaluations of this experiment on this test split: 3 (rerun reason: post_audit_rule_change — audit G2 D-1 (2026-10-06): set-target status rule set-family-1 - VAL operating points, statuses, tau and the pooled and per-dataset test gates of a set member use only windows unambiguous for it (a set window {walking, brisk_walking} / {recumbent, seated_likely} / {walking, brisk_walking, stationary} no longer counts as correct for whichever member is predicted); set families are scored as one class (reported only); locomotion merges are directed specific->general (brisk_walking->walking, stairs->walking). Bundle retrained from clean commit 744e33a7: heads, calibration and OOD reference identical to the previously sealed bundle; statuses, tau, merges, families and provenance change. Ledger entries now also record per-dataset test-split reuse (G2 D-2).); bundle.apply vs training-side numpy max |Δ| (first 2,000 windows) 0.000000000000
- test windows: capture24 96,819 (50 subj), hhar_watch 1,998 (2 subj), mhealth 49 (2 subj), opportunity 2,539 (1 subj), pamap2 5,167 (2 subj), wisdm2019_watch 1,397 (8 subj)
- nonfinite windows dropped: 0
- evaluations of each dataset's test split (any experiment, this one included; G2 D-2): capture24 67, hhar_watch 67, mhealth 67, opportunity 67, pamap2 67, wisdm2019_watch 67

† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.
*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
Limitation: leave-one-subject-out folds are defined in the split manifests (`loso_folds`) for the small datasets but were NOT evaluated; every number here comes from the single frozen train/val/test split.

### posture

Posture targets: `recumbent` is mostly Capture-24 sleep-diary lying in the training data (awake lying is reported separately below); driving/passenger (vehicle) windows carry `seated_likely` because posture is genuinely labelled there; posture is MASKED on gait/cycling/exercise windows.

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 74,475 | 0.678 | 0.473 [0.448, 0.502] | 0.460 [0.436, 0.488] | 0.460 [0.436, 0.488] | 0.976→0.704 | 0.601→0.432 | 0.074→0.108 (0.005) | 0.188→0.074 | 0.250 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `recumbent`): accuracy 0.598, balanced acc 0.333, macro-F1 0.250. Set-truth windows: 8,630; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | yes | 40,325 | 0.725 | 0.768 | 0.746 | 0.693 (35,939) | 0.115 | weak | 0.605 | P=0.794 n=16,796 → abstain | – | abstain | 0 |
| seated_likely | yes | 29,930 | 0.615 | 0.652 | 0.633 | 0.555 (25,686) | 0.086 | abstain | 1.000 | – | – | abstain | 0 |
| upright_stationary | yes | 4,220 | 0.000 | 0.000 | 0.000 | 0.000 (4,220) | 0.020 | abstain | 1.000 | – | – | abstain | 0 |
| postural_transition | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P/R/F1 = set-target scoring (a set-target window is correct for any member); P single-label = precision (argmax) on windows whose truth is exactly one class. Statuses, tau and every gate use the `set-family-1` rule: a set member is judged on its single-label evidence only (windows whose truth is a set containing it are excluded). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Set families (each scored as ONE class: merged probability, correct iff the truth lies inside the family; reported only — a family status never changes a served per-class status):

| family | test windows with exactly this set | argmax P / R (n_acc) | val status | tau | pooled gate | dataset demotions | final family status |
|---|---|---|---|---|---|---|---|
| recumbent+seated_likely | 8,630 | 0.943 / 1.000 (74,475) | strong | 0.920 | P=0.969 n=58,073 → strong | opportunity test: precision 0.811 at n_acc 37 -> weak; pamap2 test: precision 0.691 at n_acc 149 -> abstain | abstain |

Rule change (G2 D-1): the earlier set-target scoring on the same bundle and test windows vs the single-label rule:

| class | test set windows excluded | set-target val→final (tau) | single-label val→final (tau) |
|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | 8,630 | weak→abstain (0.590) | weak→abstain (0.605) |

merge_into under the old rule (symmetric table): {}

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 73,985 | 0.474 | 0.461 [0.434, 0.484] | 0.699 | 0.110 |  |
| hhar_watch | 2 | 74 | 0.243 | 0.203 [0.000, 0.333]† | 1.501 | 0.255 | descriptive |
| mhealth | 2 | 16 | 0.333 | 0.266 [0.000, 0.556]† | 1.217 | 0.304 | descriptive |
| opportunity | 1 | 37 | 0.000 | 0.000 [0.000, 0.000]† | 1.451 | 0.604 | descriptive |
| pamap2 | 2 | 204 | 0.446 | 0.321 [0.140, 0.365]† | 1.256 | 0.369 | descriptive |
| wisdm2019_watch | 8 | 159 | 0.275 | 0.208 [0.121, 0.291]† | 1.468 | 0.246 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|
| recumbent (mostly sleep-period lying in training data) | 0.73/0.77/0.75 (40277); gate P 0.80 n 16682 → abstain | 0.00/0.00/0.00 (0) | 0.40/0.50/0.44 (4); gate P 1.00 n 2 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 23 → weak | 0.31/0.91/0.46 (44); gate P 0.15 n 84 → abstain | 0.00/0.00/0.00 (0); gate P 0.00 n 5 → weak |
| seated_likely | 0.61/0.65/0.63 (29672) | 0.82/0.49/0.61 (37) | 0.27/0.50/0.35 (6) | 0.00/0.00/0.00 (30) | 0.62/0.43/0.51 (105) | 0.72/0.55/0.62 (80) |
| upright_stationary | 0.00/0.00/0.00 (4036) | 0.00/0.00/0.00 (37) | 0.00/0.00/0.00 (6) | 0.00/0.00/0.00 (7) | 0.00/0.00/0.00 (55) | 0.00/0.00/0.00 (79) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.

Awake lying (recumbent scored on NON-sleep windows only; G-2):

- recumbent truth windows: 44,569, of which sleep-period 35,904 (0.806) and awake lying 8,665 (by dataset: capture24 8576, hhar_watch 0, mhealth 4, opportunity 0, pamap2 85, wisdm2019_watch 0)
- recumbent on non-sleep windows: P 0.273, R 0.999, F1 0.429 (support 4,421, predicted 16,172)
- awake-lying gate at the frozen tau: pooled P=0.004 n=3,476 → abstain; per dataset capture24 P=0.000 n=3,362 → abstain, mhealth P=1.000 n=2 → weak, opportunity P=0.000 n=23 → weak, pamap2 P=0.155 n=84 → abstain, wisdm2019_watch P=0.000 n=5 → weak; awake-lying status abstain (reported only; the served recumbent status is the pooled one)


Wrist-only: n=74,475, macro-F1 0.460 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.799, P 0.698; ≥0.6: cov 0.319, P 0.798; ≥0.7: cov 0.092, P 0.804; ≥0.8: cov 0.001, P 0.448; ≥0.9: cov 0.000, P –; ≥0.95: cov 0.000, P –

Confusion (rows truth, cols pred; recumbent, seated_likely, upright_stationary, postural_transition):

```
  30971    9354       0       0
  10416   19514       0       0
   1341    2879       0       0
      0       0       0       0
```

### locomotion

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 91,653 | 0.809 | 0.253 [0.212, 0.288] | 0.254 [0.219, 0.277] | 0.254 [0.219, 0.277] | 1.607→0.657 | 0.880→0.310 | 0.306→0.052 (0.004) | 0.170→0.021 | 0.107 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `stationary`): accuracy 0.801, balanced acc 0.143, macro-F1 0.127. Set-truth windows: 453; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| stationary | yes | 73,403 | 0.810 | 0.998 | 0.895 | 0.810 (72,964) | 0.055 | weak | 0.300 | P=0.810 n=89,961 → weak | hhar_watch test: precision 0.474 at n_acc 156 -> abstain | abstain | 0 |
| walking | yes | 8,320 | 0.789 | 0.082 | 0.149 | 0.786 (8,306) | 0.036 | abstain | 1.000 | – | – | abstain | 0 |
| brisk_walking | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| running | yes | 203 | 0.754 | 0.680 | 0.715 | 0.767 (203) | 0.001 | weak | 0.430 | P=0.791 n=172 → abstain | – | abstain | 0 |
| stairs | yes | 152 | 0.000 | 0.000 | 0.000 | 0.000 (152) | 0.005 | abstain | 1.000 | – | – | abstain | 0 |
| cycling | yes | 808 | 0.000 | 0.000 | 0.000 | 0.000 (808) | 0.009 | abstain | 1.000 | – | – | abstain | 0 |
| vehicle_motion | yes | 3,518 | 0.000 | 0.000 | 0.000 | 0.000 (3,518) | 0.022 | abstain | 1.000 | – | – | abstain | 0 |
| other | yes | 5,249 | 0.218 | 0.008 | 0.016 | 0.222 (5,249) | 0.017 | abstain | 1.000 | – | – | abstain | 0 |

P/R/F1 = set-target scoring (a set-target window is correct for any member); P single-label = precision (argmax) on windows whose truth is exactly one class. Statuses, tau and every gate use the `set-family-1` rule: a set member is judged on its single-label evidence only (windows whose truth is a set containing it are excluded). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Set families (each scored as ONE class: merged probability, correct iff the truth lies inside the family; reported only — a family status never changes a served per-class status):

| family | test windows with exactly this set | argmax P / R (n_acc) | val status | tau | pooled gate | dataset demotions | final family status |
|---|---|---|---|---|---|---|---|
| stationary+walking | 453 | 0.893 / 0.999 (91,379) | weak | 0.300 | P=0.893 n=91,379 → weak | hhar_watch test: precision 0.626 at n_acc 174 -> abstain | abstain |

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 89,829 | 0.228 | 0.231 [0.145, 0.278] | 0.654 | 0.051 |  |
| hhar_watch | 2 | 174 | 0.257 | 0.170 [0.149, 0.189]† | 1.609 | 0.279 | descriptive |
| mhealth | 2 | 49 | 0.333 | 0.276 [0.274, 0.333]† | 1.124 | 0.240 | descriptive |
| opportunity | 1 | 37 | 1.000 | 1.000 [1.000, 1.000]† | 0.146 | 0.135 | descriptive |
| pamap2 | 2 | 397 | 0.401 | 0.309 [0.275, 0.314]† | 1.370 | 0.151 | descriptive |
| wisdm2019_watch | 8 | 1,167 | 0.546 | 0.450 [0.384, 0.504]† | 0.519 | 0.130 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | hhar_watch | mhealth | opportunity | pamap2 | wisdm2019_watch |
|---|---|---|---|---|---|---|
| stationary | 0.81/1.00/0.89 (72149); gate P 0.81 n 88378 → weak | 0.47/1.00/0.64 (74); gate P 0.47 n 156 → abstain | 0.49/1.00/0.66 (19); gate P 0.49 n 39 → abstain | 1.00/1.00/1.00 (37); gate P 1.00 n 37 → strong | 0.58/0.98/0.73 (187); gate P 0.58 n 316 → abstain | 0.89/0.99/0.94 (937); gate P 0.89 n 1035 → weak |
| walking | 0.84/0.08/0.14 (8168) | 0.06/0.03/0.04 (35) | 0.00/0.00/0.00 (4) | 0.00/0.00/0.00 (0) | 0.60/0.74/0.67 (43) | 0.49/0.39/0.43 (70) |
| running | 0.64/0.51/0.57 (103); gate P 0.70 n 76 → abstain | 0.00/0.00/0.00 (0) | 1.00/1.00/1.00 (10); gate P 1.00 n 10 → weak | 0.00/0.00/0.00 (0) | 0.45/1.00/0.62 (10); gate P 0.45 n 22 → weak | 0.96/0.81/0.88 (80); gate P 0.98 n 64 → strong |
| stairs | 0.00/0.00/0.00 (8) | 0.00/0.00/0.00 (32) | 0.00/0.00/0.00 (3) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (29) | 0.00/0.00/0.00 (80) |
| cycling | 0.00/0.00/0.00 (743) | 0.00/0.00/0.00 (33) | 0.00/0.00/0.00 (4) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (28) | 0.00/0.00/0.00 (0) |
| vehicle_motion | 0.00/0.00/0.00 (3484) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (34) | 0.00/0.00/0.00 (0) |
| other | 0.21/0.01/0.01 (5174) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (9) | 0.00/0.00/0.00 (0) | 0.83/0.08/0.14 (66) | 0.00/0.00/0.00 (0) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=91,653, macro-F1 0.254 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.987, P 0.815; ≥0.6: cov 0.970, P 0.822; ≥0.7: cov 0.921, P 0.843; ≥0.8: cov 0.548, P 0.890; ≥0.9: cov 0.044, P 0.943; ≥0.95: cov 0.001, P 0.937

Confusion (rows truth, cols pred; stationary, walking, brisk_walking, running, stairs, cycling, vehicle_motion, other):

```
  73270      47       0       9       0       0       0      77
   7551     686       0      15       0       0       0      68
      0       0       0       0       0       0       0       0
      9      52       0     138       0       0       0       4
    118      31       0       0       0       0       0       3
    796      12       0       0       0       0       0       0
   3514       2       0       0       0       0       0       2
   5145      40       0      21       0       0       0      43
```

### arm_behavior

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|---|
| 20,972 | 0.646 | 0.333 [0.333, 0.333] | 0.262 [0.240, 0.283] | 0.262 [0.240, 0.283] | 1.270→0.740 | 0.796→0.470 | 0.264→0.056 (0.009) | 0.263→0.048 | 0.307 |

macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while absent scores 0). Predicted while absent from this test set: none. 'present-only' = the earlier number over classes with test support only (kept for comparison).

Majority baseline (train-majority `desk_like`): accuracy 0.646, balanced acc 0.333, macro-F1 0.262. Set-truth windows: 0; windows whose truth is an unsupported class (not scored): 14.

| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | pooled gate | dataset demotions | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| quiet | yes | 6,845 | 0.000 | 0.000 | 0.000 | 0.000 (6,845) | 0.069 | abstain | 1.000 | – | – | abstain | 0 |
| desk_like | yes | 13,545 | 0.646 | 1.000 | 0.785 | 0.646 (13,545) | 0.056 | weak | 0.705 | P=0.719 n=10,006 → abstain | – | abstain | 0 |
| fidgeting | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| repetitive_hand_motion | yes | 582 | 0.000 | 0.000 | 0.000 | 0.000 (582) | 0.018 | abstain | 1.000 | – | – | abstain | 0 |
| active_gesturing | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |
| exercise_motion | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 14 |
| other | no | 0 | – | – | – | – | – | unsupported | – | – | – | – | 0 |

P/R/F1 = set-target scoring (a set-target window is correct for any member); P single-label = precision (argmax) on windows whose truth is exactly one class. Statuses, tau and every gate use the `set-family-1` rule: a set member is judged on its single-label evidence only (windows whose truth is a set containing it are excluded). Final status = min(val status, pooled gate, every wrist dataset with n_acc >= 30); the gate only demotes.

Per dataset (macro-F1 = union convention):

| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |
|---|---|---|---|---|---|---|---|
| capture24 | 50 | 20,580 | 0.333 | 0.263 [0.241, 0.282] | 0.721 | 0.056 |  |
| mhealth | 2 | 12 | 0.000 | 0.000 [0.000, 0.000]† | 1.383 | 0.687 | descriptive |
| pamap2 | 2 | 60 | 0.000 | 0.000 [0.000, 0.000]† | 1.991 | 0.674 | descriptive |
| wisdm2019_watch | 8 | 320 | 0.500 | 0.333 [0.333, 0.333]† | 1.691 | 0.349 |  |

Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels with n_acc < 30 do not demote):

| class | capture24 | mhealth | pamap2 | wisdm2019_watch |
|---|---|---|---|---|
| quiet | 0.00/0.00/0.00 (6802) | 0.00/0.00/0.00 (12) | 0.00/0.00/0.00 (31) | 0.00/0.00/0.00 (0) |
| desk_like | 0.65/1.00/0.79 (13385); gate P 0.72 n 9737 → abstain | 0.00/0.00/0.00 (0); gate P 0.00 n 6 → weak | 0.00/0.00/0.00 (0); gate P 0.00 n 17 → weak | 0.50/1.00/0.67 (160); gate P 0.65 n 246 → abstain |
| repetitive_hand_motion | 0.00/0.00/0.00 (393) | 0.00/0.00/0.00 (0) | 0.00/0.00/0.00 (29) | 0.00/0.00/0.00 (160) |

*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe those subjects, not a population.
† = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.


Wrist-only: n=20,972, macro-F1 0.262 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 1.000, P 0.646; ≥0.6: cov 0.957, P 0.661; ≥0.7: cov 0.504, P 0.717; ≥0.8: cov 0.038, P 0.576; ≥0.9: cov 0.000, P –; ≥0.95: cov 0.000, P –

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
| sit_to_stand_like | yes | 75,222 (385) | 0.827 | 0.024 | 0.162→0.162 | 0.341→0.312 | abstain→abstain |
| stand_to_sit_like | yes | 75,222 (518) | 0.781 | 0.023 | 0.181→0.181 | 0.349→0.357 | abstain→abstain |
| lying_down_like | no | – (0) | – | – | – | – | unsupported |
| getting_up_like | no | – (11) | – | – | – | – | unsupported |
| walk_start | yes | 75,222 (492) | 0.751 | 0.022 | 0.176→0.176 | 0.350→0.352 | abstain→abstain |
| walk_stop | yes | 75,222 (650) | 0.725 | 0.021 | 0.182→0.181 | 0.370→0.363 | abstain→abstain |
| run_start | no | – (4) | – | – | – | – | unsupported |
| run_stop | no | – (0) | – | – | – | – | unsupported |

Event-level (Opportunity/PAMAP2/HHAR dense 2-s windows; theta chosen on val):

| event | theta (val status) | true events | P/R/F1 ±5 s | P/R/F1 ±10 s | median / p90 abs error (s, ±10 s) |
|---|---|---|---|---|---|
| sit_to_stand_like | 0.65 (weak) | 36 | 0.17/0.28/0.21 | 0.22/0.36/0.28 | 2.1 / 6.5 |
| stand_to_sit_like | 0.40 (weak) | 36 | 0.05/0.14/0.07 | 0.11/0.31/0.16 | 5.1 / 8.5 |
| walk_start | 0.60 (weak) | 405 | 0.37/0.22/0.28 | 0.38/0.23/0.29 | 2.0 / 3.8 |
| walk_stop | 0.55 (weak) | 404 | 0.36/0.24/0.29 | 0.43/0.29/0.35 | 2.5 / 6.6 |

event-level timing only where ground truth supports it (Opportunity, PAMAP2, HHAR dense 2-s windows); Capture-24 supports event presence only (per-window AUROC/AP above)

### movement_intensity

Target clip(ln(MET)/ln(12),0,1) from Capture-24 annotation METs / PAMAP2 protocol METs / GOTOV measured COSMED METs per window (gotov-met-1); split-conformal 80% half-width 0.218.

| set | n | MAE | MAE const (test mean) | R² | Spearman | 80% interval coverage |
|---|---|---|---|---|---|---|
| pooled | 95,813 | 0.146 | 0.136 | 0.007 | 0.399 | 0.792 |
| capture24 | 95,579 | 0.146 | 0.136 | 0.000 | 0.397 | 0.792 |
| pamap2 | 234 | 0.150 | 0.203 | 0.346 | 0.752 | 0.782 |

## OOD

Bundle method `maha_global` (k=None), threshold 35.822 (0.95 quantile of VAL ID scores); ID test false-alarm rate 0.070 on 97,403 windows.


Measured: every table above (test subjects, once). Inferred: nothing about Inertia-1 or WHOOP straps — the encoders are stand-ins and the data are public wrist datasets.
