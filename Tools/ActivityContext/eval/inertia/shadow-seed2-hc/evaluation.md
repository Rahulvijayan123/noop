# Evaluation — `shadow-seed2-hc` (seed)

> **STAND-IN ENCODERS — NOT INERTIA-1; real Inertia-1 evaluation blocked: no public checkpoint.** Every number below is a *measured* result for a stand-in encoder on public wrist data; nothing here is evidence about Inertia-1 itself.

- bundle_sha256 `c565508a8c716e2a4f3aca4a184a2648d365081e166c0c2d0364e7e8a0d5c3b9`; encoder `standin:handcrafted-stats-v1` (standin); evidence_tier_max `shadow`
- evaluated once on the frozen test subjects through `load_bundle(...).apply(...)`; test_sha256 `6afd705530ea8f98e32f7c40997c4db53952ebdcd411fea823493c71a8311898`; evaluations of this experiment: 2 (rerun reason: run-1 bundle directory was deleted by an external process (~19:55, /tmp); bundle retrained deterministically from identical code/data/splits; no model, rule or threshold changed); bundle.apply vs training-side numpy max |Δ| (first 2,000 windows) 0.000000000000
- test windows: capture24 96,819 (50 subj), hhar_watch 1,998 (2 subj), mhealth 49 (2 subj), opportunity 2,539 (1 subj), pamap2 5,167 (2 subj), wisdm2019_watch 1,397 (8 subj)
- nonfinite windows dropped: 0

### posture

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|
| 74,475 | 0.857 | 0.643 [0.628, 0.659] | 0.655 [0.636, 0.674] | 0.533→0.387 | 0.307→0.215 | 0.052→0.026 (0.004) | 0.101→0.025 | 0.061 |

Majority baseline (train-majority `recumbent`): accuracy 0.598, balanced acc 0.333, macro-F1 0.250. Set-truth windows: 8,630; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | classwise ECE | val status | tau | test gate | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|
| recumbent | yes | 38,484 | 0.909 | 0.920 | 0.915 | 0.034 | strong | 0.845 | P=0.965 n=27,049 pass | strong | 0 |
| seated_likely | yes | 31,771 | 0.812 | 0.877 | 0.843 | 0.033 | weak | 0.300 | P=0.812 n=34,298 fail | weak | 0 |
| upright_stationary | yes | 4,220 | 0.465 | 0.132 | 0.206 | 0.007 | abstain | 1.000 | – | abstain | 0 |
| postural_transition | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |

Per dataset:

| dataset | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | per-class F1 |
|---|---|---|---|---|---|---|
| capture24 | 73,985 | 0.638 | 0.647 [0.630, 0.667] | 0.385 | 0.026 | recumbent 0.92 (n=38406), seated_likely 0.84 (n=31543), upright_stationary 0.18 (n=4036) |
| hhar_watch | 74 | 0.527 | 0.606 [0.582, 0.626] | 1.311 | 0.138 | seated_likely 0.79 (n=37), upright_stationary 0.42 (n=37) |
| mhealth | 16 | 0.389 | 0.256 [0.190, 0.317] | 0.942 | 0.391 | recumbent 0.62 (n=4), seated_likely 0.15 (n=6), upright_stationary 0.00 (n=6) |
| opportunity | 37 | 0.643 | 0.684 [0.684, 0.684] | 0.439 | 0.140 | seated_likely 0.92 (n=30), upright_stationary 0.44 (n=7) |
| pamap2 | 204 | 0.728 | 0.737 [0.625, 0.750] | 0.608 | 0.103 | recumbent 0.85 (n=74), seated_likely 0.69 (n=75), upright_stationary 0.67 (n=55) |
| wisdm2019_watch | 159 | 0.653 | 0.707 [0.567, 0.822] | 0.731 | 0.135 | seated_likely 0.70 (n=80), upright_stationary 0.72 (n=79) |

Wrist-only: n=74,475, macro-F1 0.655 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.983, P 0.862; ≥0.6: cov 0.907, P 0.884; ≥0.7: cov 0.814, P 0.905; ≥0.8: cov 0.673, P 0.929; ≥0.9: cov 0.422, P 0.956; ≥0.95: cov 0.201, P 0.970

Confusion (rows truth, cols pred; recumbent, seated_likely, upright_stationary, postural_transition):

```
  35422    3021      41       0
   3312   27858     601       0
    243    3419     558       0
      0       0       0       0
```

### locomotion

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|
| 91,653 | 0.872 | 0.656 [0.620, 0.694] | 0.687 [0.656, 0.713] | 0.543→0.369 | 0.263→0.177 | 0.065→0.021 (0.004) | 0.054→0.010 | 0.024 |

Majority baseline (train-majority `stationary`): accuracy 0.801, balanced acc 0.143, macro-F1 0.127. Set-truth windows: 453; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | classwise ECE | val status | tau | test gate | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|
| stationary | yes | 73,191 | 0.910 | 0.969 | 0.939 | 0.023 | strong | 0.700 | P=0.964 n=69,083 pass | strong | 0 |
| walking | yes | 8,532 | 0.790 | 0.573 | 0.664 | 0.013 | strong | 0.865 | P=0.982 n=2,904 pass | strong | 0 |
| brisk_walking | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |
| running | yes | 203 | 0.899 | 0.837 | 0.867 | 0.001 | strong | 0.580 | P=0.941 n=169 fail | weak | 0 |
| stairs | yes | 152 | 0.722 | 0.803 | 0.760 | 0.002 | weak | 0.300 | P=0.726 n=168 fail | weak | 0 |
| cycling | yes | 808 | 0.719 | 0.656 | 0.686 | 0.002 | weak | 0.300 | P=0.720 n=736 fail | weak | 0 |
| vehicle_motion | yes | 3,518 | 0.713 | 0.420 | 0.529 | 0.020 | weak | 0.565 | P=0.847 n=1,369 fail | weak | 0 |
| other | yes | 5,249 | 0.400 | 0.333 | 0.363 | 0.008 | abstain | 1.000 | – | abstain | 0 |

Per dataset:

| dataset | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | per-class F1 |
|---|---|---|---|---|---|---|
| capture24 | 89,829 | 0.555 | 0.569 [0.466, 0.627] | 0.372 | 0.021 | stationary 0.94 (n=71937), walking 0.66 (n=8380), running 0.76 (n=103), stairs 0.08 (n=8), cycling 0.66 (n=743), vehicle_motion 0.53 (n=3484), other 0.36 (n=5174) |
| hhar_watch | 174 | 0.985 | 0.985 [0.970, 1.000] | 0.151 | 0.115 | stationary 1.00 (n=74), walking 0.97 (n=35), stairs 1.00 (n=32), cycling 0.97 (n=33) |
| mhealth | 49 | 0.807 | 0.750 [0.728, 0.949] | 0.230 | 0.118 | stationary 0.91 (n=19), walking 0.73 (n=4), running 1.00 (n=10), stairs 0.00 (n=3), cycling 1.00 (n=4), other 0.86 (n=9) |
| opportunity | 37 | 0.919 | 0.958 [0.958, 0.958] | 0.333 | 0.231 | stationary 0.96 (n=37) |
| pamap2 | 397 | 0.798 | 0.785 [0.770, 0.928] | 0.471 | 0.049 | stationary 0.86 (n=187), walking 0.90 (n=43), running 1.00 (n=10), stairs 0.86 (n=29), cycling 0.94 (n=28), vehicle_motion 0.15 (n=34), other 0.78 (n=66) |
| wisdm2019_watch | 1,167 | 0.918 | 0.929 [0.875, 0.968] | 0.167 | 0.082 | stationary 0.99 (n=937), walking 0.88 (n=70), running 0.97 (n=80), stairs 0.87 (n=80) |

Wrist-only: n=91,653, macro-F1 0.687 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.909, P 0.919; ≥0.6: cov 0.859, P 0.943; ≥0.7: cov 0.814, P 0.961; ≥0.8: cov 0.765, P 0.974; ≥0.9: cov 0.671, P 0.985; ≥0.95: cov 0.533, P 0.990

Confusion (rows truth, cols pred; stationary, walking, brisk_walking, running, stairs, cycling, vehicle_motion, other):

```
  70939     680       0       5       3      59     386    1119
   2134    4892       0       3      23      91      92    1297
      0       0       0       0       0       0       0       0
      4      28       0     170       0       0       0       1
      3      18       0       0     122       0       0       9
    205      34       0       0       0     530       4      35
   1788      81       0       0       1       4    1478     166
   2846     459       0      11      20      53     112    1748
```

### arm_behavior

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|
| 20,972 | 0.656 | 0.460 [0.416, 0.566] | 0.448 [0.403, 0.503] | 0.915→0.706 | 0.556→0.458 | 0.078→0.058 (0.009) | 0.162→0.044 | 0.290 |

Majority baseline (train-majority `desk_like`): accuracy 0.646, balanced acc 0.333, macro-F1 0.262. Set-truth windows: 0; windows whose truth is an unsupported class (not scored): 14.

| class | supported | test support | P | R | F1 | classwise ECE | val status | tau | test gate | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|
| quiet | yes | 6,845 | 0.479 | 0.105 | 0.172 | 0.058 | abstain | 1.000 | – | abstain | 0 |
| desk_like | yes | 13,545 | 0.674 | 0.949 | 0.788 | 0.057 | weak | 0.660 | P=0.717 n=14,146 fail | weak | 0 |
| fidgeting | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |
| repetitive_hand_motion | yes | 582 | 0.466 | 0.326 | 0.384 | 0.017 | weak | 0.610 | P=0.460 n=272 fail | weak | 0 |
| active_gesturing | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |
| exercise_motion | no | 0 | – | – | – | – | unsupported | – | – | – | 14 |
| other | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |

Per dataset:

| dataset | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | per-class F1 |
|---|---|---|---|---|---|---|
| capture24 | 20,580 | 0.399 | 0.376 [0.316, 0.421] | 0.708 | 0.058 | quiet 0.17 (n=6802), desk_like 0.79 (n=13385), repetitive_hand_motion 0.17 (n=393) |
| mhealth | 12 | 0.000 | 0.000 [0.000, 0.000] | 1.594 | 0.785 | quiet 0.00 (n=12) |
| pamap2 | 60 | 0.207 | 0.293 [0.250, 0.333] | 1.242 | 0.466 | quiet 0.00 (n=31), repetitive_hand_motion 0.59 (n=29) |
| wisdm2019_watch | 320 | 0.881 | 0.887 [0.734, 0.991] | 0.443 | 0.115 | desk_like 0.91 (n=160), repetitive_hand_motion 0.87 (n=160) |

Wrist-only: n=20,972, macro-F1 0.448 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.950, P 0.667; ≥0.6: cov 0.801, P 0.694; ≥0.7: cov 0.600, P 0.725; ≥0.8: cov 0.275, P 0.738; ≥0.9: cov 0.021, P 0.672; ≥0.95: cov 0.006, P 0.656

Confusion (rows truth, cols pred; quiet, desk_like, fidgeting, repetitive_hand_motion, active_gesturing, exercise_motion, other):

```
    716    5991       0     138       0       0       0
    616   12849       0      80       0       0       0
      0       0       0       0       0       0       0
    162     230       0     190       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
```

### transition (multi-label events)

| event | supported | n (pos) | AUROC | AP | Brier raw→cal | ECE raw→cal | val→final status |
|---|---|---|---|---|---|---|---|
| sit_to_stand_like | yes | 75,222 (385) | 0.931 | 0.065 | 0.096→0.095 | 0.211→0.202 | abstain→abstain |
| stand_to_sit_like | yes | 75,222 (518) | 0.897 | 0.053 | 0.098→0.097 | 0.214→0.195 | abstain→abstain |
| lying_down_like | no | – (0) | – | – | – | – | unsupported |
| getting_up_like | no | – (11) | – | – | – | – | unsupported |
| walk_start | yes | 75,222 (492) | 0.928 | 0.095 | 0.094→0.093 | 0.207→0.195 | abstain→abstain |
| walk_stop | yes | 75,222 (650) | 0.905 | 0.078 | 0.103→0.102 | 0.229→0.206 | abstain→abstain |
| run_start | no | – (4) | – | – | – | – | unsupported |
| run_stop | no | – (0) | – | – | – | – | unsupported |

Event-level (Opportunity/PAMAP2/HHAR dense 2-s windows; theta chosen on val):

| event | theta (val status) | true events | P/R/F1 ±5 s | P/R/F1 ±10 s | median / p90 abs error (s, ±10 s) |
|---|---|---|---|---|---|
| sit_to_stand_like | 0.80 (weak) | 36 | 0.13/0.56/0.22 | 0.15/0.61/0.24 | 2.8 / 4.6 |
| stand_to_sit_like | 0.95 (weak) | 36 | 0.00/0.00/0.00 | 0.00/0.00/0.00 | – / – |
| walk_start | 0.70 (weak) | 405 | 0.43/0.38/0.40 | 0.50/0.45/0.47 | 2.4 / 6.9 |
| walk_stop | 0.75 (weak) | 404 | 0.54/0.32/0.40 | 0.65/0.39/0.48 | 2.4 / 6.8 |

event-level timing only where ground truth supports it (Opportunity, PAMAP2, HHAR dense 2-s windows); Capture-24 supports event presence only (per-window AUROC/AP above)

### movement_intensity

Target clip(ln(MET)/ln(12),0,1) from Capture-24 annotation METs / PAMAP2 protocol METs; split-conformal 80% half-width 0.138.

| set | n | MAE | MAE const (test mean) | R² | Spearman | 80% interval coverage |
|---|---|---|---|---|---|---|
| pooled | 95,813 | 0.103 | 0.136 | 0.490 | 0.795 | 0.759 |
| capture24 | 95,579 | 0.103 | 0.136 | 0.487 | 0.795 | 0.759 |
| pamap2 | 234 | 0.112 | 0.203 | 0.603 | 0.848 | 0.697 |

## OOD

Bundle method `maha_global` (k=None), threshold 14.286 (0.95 quantile of VAL ID scores); ID test false-alarm rate 0.050 on 97,403 windows.


Measured: every table above (test subjects, once). Inferred: nothing about Inertia-1 or WHOOP straps — the encoders are stand-ins and the data are public wrist datasets.
