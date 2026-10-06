# Evaluation — `shadow-linear-hc` (arch)

> **STAND-IN ENCODERS — NOT INERTIA-1; real Inertia-1 evaluation blocked: no public checkpoint.** Every number below is a *measured* result for a stand-in encoder on public wrist data; nothing here is evidence about Inertia-1 itself.

- bundle_sha256 `b68e2cecc6fa66316677976ed438fc5e06a5d98db8955a907cdf38c107410fed`; encoder `standin:handcrafted-stats-v1` (standin); evidence_tier_max `shadow`
- evaluated once on the frozen test subjects through `load_bundle(...).apply(...)`; test_sha256 `6afd705530ea8f98e32f7c40997c4db53952ebdcd411fea823493c71a8311898`; evaluations of this experiment: 2 (rerun reason: run-1 bundle directory was deleted by an external process (~19:55, /tmp); bundle retrained deterministically from identical code/data/splits; no model, rule or threshold changed); bundle.apply vs training-side numpy max |Δ| (first 2,000 windows) 0.000000000000
- test windows: capture24 96,819 (50 subj), hhar_watch 1,998 (2 subj), mhealth 49 (2 subj), opportunity 2,539 (1 subj), pamap2 5,167 (2 subj), wisdm2019_watch 1,397 (8 subj)
- nonfinite windows dropped: 0

### posture

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|
| 74,475 | 0.847 | 0.617 [0.605, 0.627] | 0.618 [0.605, 0.628] | 0.599→0.413 | 0.346→0.231 | 0.043→0.014 (0.004) | 0.131→0.031 | 0.070 |

Majority baseline (train-majority `recumbent`): accuracy 0.598, balanced acc 0.333, macro-F1 0.250. Set-truth windows: 8,630; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | classwise ECE | val status | tau | test gate | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|
| recumbent | yes | 38,714 | 0.894 | 0.928 | 0.911 | 0.036 | strong | 0.890 | P=0.974 n=21,444 pass | strong | 0 |
| seated_likely | yes | 31,541 | 0.808 | 0.851 | 0.829 | 0.043 | weak | 0.300 | P=0.808 n=33,218 fail | weak | 0 |
| upright_stationary | yes | 4,220 | 0.288 | 0.071 | 0.114 | 0.015 | abstain | 1.000 | – | abstain | 0 |
| postural_transition | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |

Per dataset:

| dataset | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | per-class F1 |
|---|---|---|---|---|---|---|
| capture24 | 73,985 | 0.617 | 0.618 [0.606, 0.630] | 0.409 | 0.015 | recumbent 0.91 (n=38634), seated_likely 0.83 (n=31315), upright_stationary 0.11 (n=4036) |
| hhar_watch | 74 | 0.297 | 0.297 [0.273, 0.317] | 1.844 | 0.325 | seated_likely 0.59 (n=37), upright_stationary 0.00 (n=37) |
| mhealth | 16 | 0.556 | 0.433 [0.317, 0.556] | 1.385 | 0.195 | recumbent 0.80 (n=4), seated_likely 0.50 (n=6), upright_stationary 0.00 (n=6) |
| opportunity | 37 | 0.500 | 0.448 [0.448, 0.448] | 0.454 | 0.124 | seated_likely 0.90 (n=30), upright_stationary 0.00 (n=7) |
| pamap2 | 204 | 0.601 | 0.562 [0.432, 0.571] | 0.737 | 0.116 | recumbent 0.86 (n=76), seated_likely 0.64 (n=73), upright_stationary 0.19 (n=55) |
| wisdm2019_watch | 159 | 0.457 | 0.423 [0.272, 0.549] | 0.950 | 0.238 | seated_likely 0.60 (n=80), upright_stationary 0.24 (n=79) |

Wrist-only: n=74,475, macro-F1 0.618 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.985, P 0.851; ≥0.6: cov 0.920, P 0.869; ≥0.7: cov 0.831, P 0.890; ≥0.8: cov 0.688, P 0.913; ≥0.9: cov 0.412, P 0.945; ≥0.95: cov 0.171, P 0.968

Confusion (rows truth, cols pred; recumbent, seated_likely, upright_stationary, postural_transition):

```
  35945    2731      38       0
   3999   26838     704       0
    271    3649     300       0
      0       0       0       0
```

### locomotion

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|
| 91,653 | 0.860 | 0.564 [0.506, 0.616] | 0.620 [0.572, 0.658] | 0.796→0.424 | 0.376→0.198 | 0.153→0.037 (0.004) | 0.092→0.016 | 0.032 |

Majority baseline (train-majority `stationary`): accuracy 0.801, balanced acc 0.143, macro-F1 0.127. Set-truth windows: 453; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | classwise ECE | val status | tau | test gate | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|
| stationary | yes | 73,213 | 0.889 | 0.978 | 0.932 | 0.041 | strong | 0.790 | P=0.963 n=66,486 pass | strong | 0 |
| walking | yes | 8,510 | 0.818 | 0.508 | 0.627 | 0.015 | strong | 0.900 | P=0.986 n=2,196 pass | strong | 0 |
| brisk_walking | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |
| running | yes | 203 | 0.951 | 0.665 | 0.783 | 0.003 | strong | 0.300 | P=0.951 n=142 pass | strong | 0 |
| stairs | yes | 152 | 0.690 | 0.763 | 0.725 | 0.004 | weak | 0.500 | P=0.752 n=137 fail | weak | 0 |
| cycling | yes | 808 | 0.715 | 0.546 | 0.619 | 0.004 | weak | 0.300 | P=0.718 n=614 fail | weak | 0 |
| vehicle_motion | yes | 3,518 | 0.760 | 0.246 | 0.372 | 0.026 | abstain | 1.000 | – | abstain | 0 |
| other | yes | 5,249 | 0.343 | 0.243 | 0.284 | 0.017 | abstain | 1.000 | – | abstain | 0 |

Per dataset:

| dataset | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | per-class F1 |
|---|---|---|---|---|---|---|
| capture24 | 89,829 | 0.465 | 0.508 [0.404, 0.564] | 0.426 | 0.038 | stationary 0.93 (n=71959), walking 0.62 (n=8358), running 0.65 (n=103), stairs 0.10 (n=8), cycling 0.60 (n=743), vehicle_motion 0.37 (n=3484), other 0.28 (n=5174) |
| hhar_watch | 174 | 0.887 | 0.902 [0.847, 0.944] | 0.307 | 0.097 | stationary 0.92 (n=74), walking 0.97 (n=35), stairs 0.98 (n=32), cycling 0.73 (n=33) |
| mhealth | 49 | 0.788 | 0.736 [0.728, 0.922] | 0.375 | 0.118 | stationary 0.89 (n=19), walking 0.73 (n=4), running 1.00 (n=10), stairs 0.00 (n=3), cycling 1.00 (n=4), other 0.80 (n=9) |
| opportunity | 37 | 1.000 | 1.000 [1.000, 1.000] | 0.238 | 0.202 | stationary 1.00 (n=37) |
| pamap2 | 397 | 0.764 | 0.759 [0.736, 0.895] | 0.529 | 0.037 | stationary 0.87 (n=187), walking 0.78 (n=43), running 1.00 (n=10), stairs 0.72 (n=29), cycling 0.92 (n=28), vehicle_motion 0.21 (n=34), other 0.81 (n=66) |
| wisdm2019_watch | 1,167 | 0.853 | 0.875 [0.783, 0.953] | 0.279 | 0.069 | stationary 0.98 (n=937), walking 0.85 (n=70), running 0.87 (n=80), stairs 0.80 (n=80) |

Wrist-only: n=91,653, macro-F1 0.620 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.933, P 0.895; ≥0.6: cov 0.882, P 0.919; ≥0.7: cov 0.829, P 0.942; ≥0.8: cov 0.756, P 0.964; ≥0.9: cov 0.589, P 0.981; ≥0.95: cov 0.367, P 0.987

Confusion (rows truth, cols pred; stationary, walking, brisk_walking, running, stairs, cycling, vehicle_motion, other):

```
  71638     482       0       4       0      62     142     885
   2607    4325       0       2      34      58      81    1403
      0       0       0       0       0       0       0       0
      4      56       0     135       7       0       0       1
      3      22       0       0     116       0       0      11
    292      32       0       0       0     441       1      42
   2465      66       0       0       0      17     866     104
   3568     305       0       1      11      39      49    1276
```

### arm_behavior

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|
| 20,972 | 0.643 | 0.434 [0.392, 0.546] | 0.422 [0.375, 0.486] | 0.938→0.705 | 0.571→0.461 | 0.093→0.072 (0.010) | 0.171→0.054 | 0.265 |

Majority baseline (train-majority `desk_like`): accuracy 0.646, balanced acc 0.333, macro-F1 0.262. Set-truth windows: 0; windows whose truth is an unsupported class (not scored): 14.

| class | supported | test support | P | R | F1 | classwise ECE | val status | tau | test gate | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|
| quiet | yes | 6,845 | 0.413 | 0.093 | 0.152 | 0.077 | abstain | 1.000 | – | abstain | 0 |
| desk_like | yes | 13,545 | 0.666 | 0.937 | 0.778 | 0.069 | abstain | 1.000 | – | abstain | 0 |
| fidgeting | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |
| repetitive_hand_motion | yes | 582 | 0.438 | 0.271 | 0.335 | 0.016 | weak | 0.535 | P=0.455 n=253 fail | weak | 0 |
| active_gesturing | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |
| exercise_motion | no | 0 | – | – | – | – | unsupported | – | – | – | 14 |
| other | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |

Per dataset:

| dataset | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | per-class F1 |
|---|---|---|---|---|---|---|
| capture24 | 20,580 | 0.368 | 0.341 [0.299, 0.389] | 0.705 | 0.073 | quiet 0.15 (n=6802), desk_like 0.78 (n=13385), repetitive_hand_motion 0.09 (n=393) |
| mhealth | 12 | 0.000 | 0.000 [0.000, 0.000] | 1.641 | 0.798 | quiet 0.00 (n=12) |
| pamap2 | 60 | 0.240 | 0.341 [0.286, 0.389] | 1.269 | 0.390 | quiet 0.06 (n=31), repetitive_hand_motion 0.62 (n=29) |
| wisdm2019_watch | 320 | 0.863 | 0.860 [0.709, 0.981] | 0.550 | 0.139 | desk_like 0.88 (n=160), repetitive_hand_motion 0.84 (n=160) |

Wrist-only: n=20,972, macro-F1 0.422 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.951, P 0.653; ≥0.6: cov 0.803, P 0.681; ≥0.7: cov 0.602, P 0.721; ≥0.8: cov 0.282, P 0.788; ≥0.9: cov 0.022, P 0.759; ≥0.95: cov 0.006, P 0.631

Confusion (rows truth, cols pred; quiet, desk_like, fidgeting, repetitive_hand_motion, active_gesturing, exercise_motion, other):

```
    640    6090       0     115       0       0       0
    771   12686       0      88       0       0       0
      0       0       0       0       0       0       0
    139     285       0     158       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
```

### transition (multi-label events)

| event | supported | n (pos) | AUROC | AP | Brier raw→cal | ECE raw→cal | val→final status |
|---|---|---|---|---|---|---|---|
| sit_to_stand_like | yes | 75,222 (385) | 0.926 | 0.063 | 0.102→0.099 | 0.235→0.213 | abstain→abstain |
| stand_to_sit_like | yes | 75,222 (518) | 0.893 | 0.053 | 0.101→0.099 | 0.226→0.200 | abstain→abstain |
| lying_down_like | no | – (0) | – | – | – | – | unsupported |
| getting_up_like | no | – (11) | – | – | – | – | unsupported |
| walk_start | yes | 75,222 (492) | 0.923 | 0.091 | 0.104→0.101 | 0.232→0.214 | abstain→abstain |
| walk_stop | yes | 75,222 (650) | 0.900 | 0.075 | 0.107→0.104 | 0.239→0.212 | abstain→abstain |
| run_start | no | – (4) | – | – | – | – | unsupported |
| run_stop | no | – (0) | – | – | – | – | unsupported |

Event-level (Opportunity/PAMAP2/HHAR dense 2-s windows; theta chosen on val):

| event | theta (val status) | true events | P/R/F1 ±5 s | P/R/F1 ±10 s | median / p90 abs error (s, ±10 s) |
|---|---|---|---|---|---|
| sit_to_stand_like | 0.80 (weak) | 36 | 0.12/0.53/0.19 | 0.14/0.61/0.22 | 2.9 / 5.4 |
| stand_to_sit_like | 0.95 (weak) | 36 | 0.00/0.00/0.00 | 0.00/0.00/0.00 | – / – |
| walk_start | 0.80 (weak) | 405 | 0.51/0.35/0.42 | 0.58/0.40/0.47 | 2.3 / 5.9 |
| walk_stop | 0.60 (weak) | 404 | 0.43/0.35/0.39 | 0.54/0.44/0.48 | 2.5 / 7.0 |

event-level timing only where ground truth supports it (Opportunity, PAMAP2, HHAR dense 2-s windows); Capture-24 supports event presence only (per-window AUROC/AP above)

### movement_intensity

Target clip(ln(MET)/ln(12),0,1) from Capture-24 annotation METs / PAMAP2 protocol METs; split-conformal 80% half-width 0.139.

| set | n | MAE | MAE const (test mean) | R² | Spearman | 80% interval coverage |
|---|---|---|---|---|---|---|
| pooled | 95,813 | 0.103 | 0.136 | 0.495 | 0.780 | 0.765 |
| capture24 | 95,579 | 0.103 | 0.136 | 0.492 | 0.779 | 0.765 |
| pamap2 | 234 | 0.107 | 0.203 | 0.645 | 0.845 | 0.697 |

## OOD

Bundle method `maha_global` (k=None), threshold 14.286 (0.95 quantile of VAL ID scores); ID test false-alarm rate 0.050 on 97,403 windows.


Measured: every table above (test subjects, once). Inferred: nothing about Inertia-1 or WHOOP straps — the encoders are stand-ins and the data are public wrist datasets.
