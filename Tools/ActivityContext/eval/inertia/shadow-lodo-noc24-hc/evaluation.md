# Evaluation — `shadow-lodo-noc24-hc` (lodo)

> **STAND-IN ENCODERS — NOT INERTIA-1; real Inertia-1 evaluation blocked: no public checkpoint.** Every number below is a *measured* result for a stand-in encoder on public wrist data; nothing here is evidence about Inertia-1 itself.

- bundle_sha256 `f5793b3ac33c64da066782c52519435f6f1e02020bbaf873f9ad138219d604a1`; encoder `standin:handcrafted-stats-v1` (standin); evidence_tier_max `shadow`
- evaluated once on the frozen test subjects through `load_bundle(...).apply(...)`; test_sha256 `6afd705530ea8f98e32f7c40997c4db53952ebdcd411fea823493c71a8311898`; evaluations of this experiment: 2 (rerun reason: run-1 bundle directory was deleted by an external process (~19:55, /tmp); bundle retrained deterministically from identical code/data/splits; no model, rule or threshold changed); bundle.apply vs training-side numpy max |Δ| (first 2,000 windows) 0.000000000000
- test windows: capture24 96,819 (50 subj), hhar_watch 1,998 (2 subj), mhealth 49 (2 subj), opportunity 2,539 (1 subj), pamap2 5,167 (2 subj), wisdm2019_watch 1,397 (8 subj)
- nonfinite windows dropped: 0

### posture

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|
| 29,906 | 0.467 | 0.588 [0.538, 0.643] | 0.430 [0.380, 0.480] | 1.021→0.939 | 0.716→0.679 | 0.296→0.268 (0.008) | 0.423→0.417 | 0.528 |

Majority baseline (train-majority `seated_likely`): accuracy 0.859, balanced acc 0.500, macro-F1 0.462. Set-truth windows: 0; windows whose truth is an unsupported class (not scored): 53,199.

| class | supported | test support | P | R | F1 | classwise ECE | val status | tau | test gate | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|
| recumbent | no | 0 | – | – | – | – | unsupported | – | – | – | 44,569 |
| seated_likely | yes | 25,686 | 0.913 | 0.419 | 0.575 | 0.417 | strong | 0.860 | P=0.989 n=2,450 pass | strong | 8,630 |
| upright_stationary | yes | 4,220 | 0.176 | 0.756 | 0.286 | 0.417 | weak | 0.645 | P=0.163 n=13,204 fail | weak | 0 |
| postural_transition | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |

Per dataset:

| dataset | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | per-class F1 |
|---|---|---|---|---|---|---|
| capture24 | 29,505 | 0.583 | 0.424 [0.373, 0.468] | 0.946 | 0.272 | seated_likely 0.57 (n=25469), upright_stationary 0.28 (n=4036) |
| hhar_watch | 74 | 0.919 | 0.919 [0.840, 1.000] | 0.369 | 0.193 | seated_likely 0.92 (n=37), upright_stationary 0.91 (n=37) |
| mhealth | 12 | 0.417 | 0.378 [0.333, 0.378] | 0.727 | 0.192 | seated_likely 0.53 (n=6), upright_stationary 0.22 (n=6) |
| opportunity | 37 | 0.714 | 0.769 [0.769, 0.769] | 0.322 | 0.116 | seated_likely 0.94 (n=30), upright_stationary 0.60 (n=7) |
| pamap2 | 119 | 0.703 | 0.661 [0.491, 0.951] | 0.596 | 0.079 | seated_likely 0.58 (n=64), upright_stationary 0.74 (n=55) |
| wisdm2019_watch | 159 | 0.894 | 0.892 [0.756, 1.000] | 0.377 | 0.074 | seated_likely 0.88 (n=80), upright_stationary 0.90 (n=79) |

Wrist-only: n=29,906, macro-F1 0.430 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 1.000, P 0.467; ≥0.6: cov 0.794, P 0.463; ≥0.7: cov 0.596, P 0.459; ≥0.8: cov 0.379, P 0.454; ≥0.9: cov 0.100, P 0.487; ≥0.95: cov 0.001, P 0.944

Confusion (rows truth, cols pred; recumbent, seated_likely, upright_stationary, postural_transition):

```
      0       0       0       0
      0   10770   14916       0
      0    1029    3191       0
      0       0       0       0
```

### locomotion

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|
| 82,078 | 0.932 | 0.746 [0.670, 0.819] | 0.655 [0.600, 0.707] | 0.381→0.380 | 0.125→0.123 | 0.045→0.051 (0.001) | 0.031→0.031 | 0.025 |

Majority baseline (train-majority `stationary`): accuracy 0.894, balanced acc 0.250, macro-F1 0.236. Set-truth windows: 453; windows whose truth is an unsupported class (not scored): 9,575.

| class | supported | test support | P | R | F1 | classwise ECE | val status | tau | test gate | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|
| stationary | yes | 73,286 | 0.938 | 0.998 | 0.967 | 0.050 | strong | 0.300 | P=0.938 n=77,981 fail | weak | 0 |
| walking | yes | 8,437 | 0.961 | 0.368 | 0.532 | 0.062 | strong | 0.745 | P=0.974 n=2,676 pass | strong | 0 |
| brisk_walking | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |
| running | yes | 203 | 0.902 | 0.729 | 0.807 | 0.001 | strong | 0.855 | P=0.982 n=112 pass | strong | 0 |
| stairs | yes | 152 | 0.192 | 0.888 | 0.316 | 0.012 | strong | 0.565 | P=0.255 n=517 fail | weak | 0 |
| cycling | no | 0 | – | – | – | – | unsupported | – | – | – | 808 |
| vehicle_motion | no | 0 | – | – | – | – | unsupported | – | – | – | 3,518 |
| other | no | 0 | – | – | – | – | unsupported | – | – | – | 5,249 |

Per dataset:

| dataset | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | per-class F1 |
|---|---|---|---|---|---|---|
| capture24 | 80,428 | 0.530 | 0.528 [0.359, 0.625] | 0.387 | 0.052 | stationary 0.97 (n=72032), walking 0.52 (n=8285), running 0.62 (n=103), stairs 0.01 (n=8) |
| hhar_watch | 141 | 0.990 | 0.990 [0.980, 1.000] | 0.040 | 0.027 | stationary 1.00 (n=74), walking 0.99 (n=35), stairs 0.98 (n=32) |
| mhealth | 36 | 0.833 | 0.825 [0.792, 1.000] | 0.101 | 0.069 | stationary 1.00 (n=19), walking 0.80 (n=4), running 1.00 (n=10), stairs 0.50 (n=3) |
| opportunity | 37 | 1.000 | 1.000 [1.000, 1.000] | 0.001 | 0.001 | stationary 1.00 (n=37) |
| pamap2 | 269 | 0.989 | 0.975 [0.967, 0.980] | 0.084 | 0.046 | stationary 0.99 (n=187), walking 0.99 (n=43), running 1.00 (n=10), stairs 0.92 (n=29) |
| wisdm2019_watch | 1,167 | 0.937 | 0.957 [0.915, 0.992] | 0.064 | 0.016 | stationary 0.99 (n=937), walking 0.93 (n=70), running 0.97 (n=80), stairs 0.94 (n=80) |

Wrist-only: n=82,078, macro-F1 0.655 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.997, P 0.934; ≥0.6: cov 0.991, P 0.937; ≥0.7: cov 0.984, P 0.940; ≥0.8: cov 0.974, P 0.944; ≥0.9: cov 0.958, P 0.949; ≥0.95: cov 0.936, P 0.955

Confusion (rows truth, cols pred; stationary, walking, brisk_walking, running, stairs, cycling, vehicle_motion, other):

```
  73118      78       0       3      87       0       0       0
   4843    3104       0      13     477       0       0       0
      0       0       0       0       0       0       0       0
      7      45       0     148       3       0       0       0
     13       4       0       0     135       0       0       0
      0       0       0       0       0       0       0       0
      0       0       0       0       0       0       0       0
      0       0       0       0       0       0       0       0
```

### arm_behavior

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|
| 14,127 | 0.535 | 0.731 [0.657, 0.781] | 0.412 [0.348, 0.474] | 0.489→0.816 | 0.325→0.579 | 0.032→0.199 (0.012) | 0.289→0.455 | 0.412 |

Majority baseline (train-majority `desk_like`): accuracy 0.959, balanced acc 0.500, macro-F1 0.489. Set-truth windows: 0; windows whose truth is an unsupported class (not scored): 6,859.

| class | supported | test support | P | R | F1 | classwise ECE | val status | tau | test gate | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|
| quiet | no | 0 | – | – | – | – | unsupported | – | – | – | 6,845 |
| desk_like | yes | 13,545 | 0.995 | 0.518 | 0.681 | 0.455 | abstain | 1.000 | – | abstain | 0 |
| fidgeting | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |
| repetitive_hand_motion | yes | 582 | 0.078 | 0.945 | 0.143 | 0.455 | strong | 0.555 | P=0.085 n=6,349 fail | weak | 0 |
| active_gesturing | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |
| exercise_motion | no | 0 | – | – | – | – | unsupported | – | – | – | 14 |
| other | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |

Per dataset:

| dataset | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | per-class F1 |
|---|---|---|---|---|---|---|
| capture24 | 13,778 | 0.753 | 0.392 [0.328, 0.464] | 0.828 | 0.207 | desk_like 0.68 (n=13385), repetitive_hand_motion 0.11 (n=393) |
| pamap2 | 29 | 1.000 | 1.000 [1.000, 1.000] | 0.138 | 0.128 | repetitive_hand_motion 1.00 (n=29) |
| wisdm2019_watch | 320 | 0.897 | 0.896 [0.761, 0.991] | 0.372 | 0.150 | desk_like 0.90 (n=160), repetitive_hand_motion 0.89 (n=160) |

Wrist-only: n=14,127, macro-F1 0.412 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 1.000, P 0.535; ≥0.6: cov 0.806, P 0.546; ≥0.7: cov 0.588, P 0.573; ≥0.8: cov 0.344, P 0.618; ≥0.9: cov 0.116, P 0.666; ≥0.95: cov 0.023, P 0.520

Confusion (rows truth, cols pred; quiet, desk_like, fidgeting, repetitive_hand_motion, active_gesturing, exercise_motion, other):

```
      0       0       0       0       0       0       0
      0    7010       0    6535       0       0       0
      0       0       0       0       0       0       0
      0      32       0     550       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
```

### movement_intensity

Target clip(ln(MET)/ln(12),0,1) from Capture-24 annotation METs / PAMAP2 protocol METs; split-conformal 80% half-width 0.270.

| set | n | MAE | MAE const (test mean) | R² | Spearman | 80% interval coverage |
|---|---|---|---|---|---|---|
| pooled | 95,813 | 0.223 | 0.136 | -1.315 | 0.660 | 0.659 |
| capture24 | 95,579 | 0.224 | 0.136 | -1.337 | 0.661 | 0.658 |
| pamap2 | 234 | 0.108 | 0.203 | 0.653 | 0.814 | 0.953 |

## OOD

Bundle method `maha_global` (k=None), threshold 13.552 (0.95 quantile of VAL ID scores); ID test false-alarm rate 0.065 on 97,403 windows.


Measured: every table above (test subjects, once). Inferred: nothing about Inertia-1 or WHOOP straps — the encoders are stand-ins and the data are public wrist datasets.
