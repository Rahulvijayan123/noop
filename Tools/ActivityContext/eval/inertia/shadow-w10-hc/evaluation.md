# Evaluation — `shadow-w10-hc` (window)

> **STAND-IN ENCODERS — NOT INERTIA-1; real Inertia-1 evaluation blocked: no public checkpoint.** Every number below is a *measured* result for a stand-in encoder on public wrist data; nothing here is evidence about Inertia-1 itself.

- bundle_sha256 `e1256ed06c23ed21b840663a6c6d769e46b0ad9f6c64952e96e034453557631b`; encoder `standin:handcrafted-stats-v1` (standin); evidence_tier_max `shadow`
- evaluated once on the frozen test subjects through `load_bundle(...).apply(...)`; test_sha256 `fe25fb43c8cbb546f6215785ebcb3dd25a0f117d5025a92781759edb3e1a4b2e`; evaluations of this experiment: 2 (rerun reason: run-1 bundle directory was deleted by an external process (~19:55, /tmp); bundle retrained deterministically from identical code/data/splits; no model, rule or threshold changed); bundle.apply vs training-side numpy max |Δ| (first 2,000 windows) 0.000000000000
- test windows: capture24 293,623 (50 subj), hhar_watch 617 (2 subj), mhealth 221 (2 subj), opportunity 245 (1 subj), pamap2 1,314 (2 subj), wisdm2019_watch 4,756 (8 subj)
- nonfinite windows dropped: 0

### posture

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|
| 227,293 | 0.831 | 0.613 [0.600, 0.625] | 0.618 [0.601, 0.634] | 0.582→0.454 | 0.340→0.255 | 0.055→0.043 (0.003) | 0.086→0.033 | 0.083 |

Majority baseline (train-majority `seated_likely`): accuracy 0.466, balanced acc 0.333, macro-F1 0.212. Set-truth windows: 26,872; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | classwise ECE | val status | tau | test gate | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|
| recumbent | yes | 116,829 | 0.875 | 0.907 | 0.891 | 0.052 | weak | 0.300 | P=0.875 n=121,077 fail | weak | 0 |
| seated_likely | yes | 96,936 | 0.789 | 0.843 | 0.815 | 0.042 | weak | 0.515 | P=0.799 n=98,292 fail | weak | 0 |
| upright_stationary | yes | 13,528 | 0.451 | 0.088 | 0.147 | 0.005 | abstain | 1.000 | – | abstain | 0 |
| postural_transition | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |

Per dataset:

| dataset | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | per-class F1 |
|---|---|---|---|---|---|---|
| capture24 | 225,565 | 0.607 | 0.610 [0.594, 0.627] | 0.451 | 0.044 | recumbent 0.89 (n=116555), seated_likely 0.82 (n=96180), upright_stationary 0.12 (n=12830) |
| hhar_watch | 233 | 0.665 | 0.672 [0.591, 0.734] | 0.919 | 0.152 | seated_likely 0.84 (n=118), upright_stationary 0.50 (n=115) |
| mhealth | 66 | 0.439 | 0.355 [0.222, 0.475] | 0.809 | 0.272 | recumbent 0.73 (n=22), seated_likely 0.24 (n=22), upright_stationary 0.09 (n=22) |
| opportunity | 239 | 0.463 | 0.430 [0.430, 0.430] | 1.008 | 0.206 | recumbent 0.31 (n=18), seated_likely 0.69 (n=112), upright_stationary 0.29 (n=109) |
| pamap2 | 647 | 0.599 | 0.596 [0.544, 0.614] | 0.797 | 0.099 | recumbent 0.73 (n=234), seated_likely 0.45 (n=232), upright_stationary 0.61 (n=181) |
| wisdm2019_watch | 543 | 0.626 | 0.676 [0.553, 0.775] | 0.779 | 0.085 | seated_likely 0.71 (n=272), upright_stationary 0.65 (n=271) |

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

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|
| 282,152 | 0.855 | 0.589 [0.560, 0.619] | 0.616 [0.583, 0.641] | 0.715→0.434 | 0.369→0.205 | 0.063→0.021 (0.002) | 0.078→0.011 | 0.033 |

Majority baseline (train-majority `stationary`): accuracy 0.795, balanced acc 0.143, macro-F1 0.127. Set-truth windows: 1,438; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | classwise ECE | val status | tau | test gate | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|
| stationary | yes | 223,808 | 0.884 | 0.977 | 0.928 | 0.023 | strong | 0.790 | P=0.963 n=198,478 pass | strong | 0 |
| walking | yes | 27,293 | 0.782 | 0.506 | 0.614 | 0.014 | strong | 0.790 | P=0.967 n=8,849 pass | strong | 0 |
| brisk_walking | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |
| running | yes | 669 | 0.877 | 0.867 | 0.872 | 0.001 | strong | 0.540 | P=0.907 n=604 fail | weak | 0 |
| stairs | yes | 591 | 0.543 | 0.658 | 0.595 | 0.002 | weak | 0.505 | P=0.707 n=501 fail | weak | 0 |
| cycling | yes | 2,536 | 0.627 | 0.618 | 0.623 | 0.003 | weak | 0.395 | P=0.657 n=2,356 fail | weak | 0 |
| vehicle_motion | yes | 10,735 | 0.754 | 0.316 | 0.445 | 0.025 | abstain | 1.000 | – | abstain | 0 |
| other | yes | 16,520 | 0.336 | 0.181 | 0.235 | 0.010 | abstain | 1.000 | – | abstain | 0 |

Per dataset:

| dataset | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | per-class F1 |
|---|---|---|---|---|---|---|
| capture24 | 275,781 | 0.499 | 0.516 [0.419, 0.579] | 0.437 | 0.022 | stationary 0.93 (n=219468), walking 0.61 (n=26752), running 0.78 (n=319), stairs 0.02 (n=29), cycling 0.60 (n=2317), vehicle_motion 0.45 (n=10628), other 0.22 (n=16268) |
| hhar_watch | 617 | 0.936 | 0.935 [0.928, 0.937] | 0.239 | 0.100 | stationary 0.99 (n=233), walking 0.88 (n=114), stairs 0.93 (n=163), cycling 0.94 (n=107) |
| mhealth | 221 | 0.880 | 0.873 [0.817, 0.948] | 0.248 | 0.071 | stationary 0.96 (n=83), walking 0.81 (n=21), running 0.98 (n=41), stairs 0.64 (n=15), cycling 1.00 (n=22), other 0.86 (n=39) |
| opportunity | 245 | 0.721 | 0.734 [0.734, 0.734] | 0.416 | 0.196 | stationary 0.97 (n=239), walking 0.50 (n=6) |
| pamap2 | 1,314 | 0.752 | 0.748 [0.748, 0.869] | 0.578 | 0.049 | stationary 0.85 (n=593), walking 0.86 (n=162), running 0.99 (n=37), stairs 0.81 (n=112), cycling 0.93 (n=90), vehicle_motion 0.00 (n=107), other 0.80 (n=213) |
| wisdm2019_watch | 3,974 | 0.849 | 0.860 [0.801, 0.908] | 0.217 | 0.072 | stationary 0.99 (n=3192), walking 0.78 (n=238), running 0.95 (n=272), stairs 0.72 (n=272) |

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

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|
| 64,906 | 0.641 | 0.443 [0.404, 0.552] | 0.430 [0.379, 0.498] | 0.936→0.708 | 0.594→0.466 | 0.118→0.069 (0.005) | 0.183→0.052 | 0.274 |

Majority baseline (train-majority `desk_like`): accuracy 0.640, balanced acc 0.333, macro-F1 0.260. Set-truth windows: 0; windows whose truth is an unsupported class (not scored): 62.

| class | supported | test support | P | R | F1 | classwise ECE | val status | tau | test gate | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|
| quiet | yes | 21,537 | 0.410 | 0.068 | 0.116 | 0.074 | abstain | 1.000 | – | abstain | 0 |
| desk_like | yes | 41,544 | 0.656 | 0.952 | 0.777 | 0.072 | weak | 0.715 | P=0.724 n=35,582 fail | weak | 0 |
| fidgeting | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |
| repetitive_hand_motion | yes | 1,825 | 0.546 | 0.311 | 0.396 | 0.011 | strong | 0.955 | P=0.826 n=207 fail | weak | 0 |
| active_gesturing | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |
| exercise_motion | no | 0 | – | – | – | – | unsupported | – | – | – | 62 |
| other | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |

Per dataset:

| dataset | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | per-class F1 |
|---|---|---|---|---|---|---|
| capture24 | 63,583 | 0.369 | 0.337 [0.289, 0.368] | 0.709 | 0.070 | quiet 0.12 (n=21396), desk_like 0.78 (n=41000), repetitive_hand_motion 0.12 (n=1187) |
| mhealth | 44 | 0.000 | 0.000 [0.000, 0.000] | 1.397 | 0.745 | quiet 0.00 (n=44) |
| pamap2 | 191 | 0.351 | 0.412 [0.351, 0.465] | 1.170 | 0.398 | quiet 0.00 (n=97), repetitive_hand_motion 0.82 (n=94) |
| wisdm2019_watch | 1,088 | 0.865 | 0.865 [0.709, 0.975] | 0.529 | 0.122 | desk_like 0.88 (n=544), repetitive_hand_motion 0.85 (n=544) |

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
