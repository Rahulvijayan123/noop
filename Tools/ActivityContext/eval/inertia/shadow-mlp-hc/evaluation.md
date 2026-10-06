# Evaluation — `shadow-mlp-hc` (arch)

> **STAND-IN ENCODERS — NOT INERTIA-1; real Inertia-1 evaluation blocked: no public checkpoint.** Every number below is a *measured* result for a stand-in encoder on public wrist data; nothing here is evidence about Inertia-1 itself.

- bundle_sha256 `f4c14ff205e8863f254f2d012adb3b8f44f20ee4d9c48a61dc79888a25807146`; encoder `standin:handcrafted-stats-v1` (standin); evidence_tier_max `shadow`
- evaluated once on the frozen test subjects through `load_bundle(...).apply(...)`; test_sha256 `6afd705530ea8f98e32f7c40997c4db53952ebdcd411fea823493c71a8311898`; evaluations of this experiment: 2 (rerun reason: run-1 bundle directory was deleted by an external process (~19:55, /tmp); bundle retrained deterministically from identical code/data/splits; no model, rule or threshold changed); bundle.apply vs training-side numpy max |Δ| (first 2,000 windows) 0.000000000000
- test windows: capture24 96,819 (50 subj), hhar_watch 1,998 (2 subj), mhealth 49 (2 subj), opportunity 2,539 (1 subj), pamap2 5,167 (2 subj), wisdm2019_watch 1,397 (8 subj)
- nonfinite windows dropped: 0

### posture

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|
| 74,475 | 0.857 | 0.645 [0.629, 0.661] | 0.657 [0.638, 0.676] | 0.536→0.389 | 0.308→0.216 | 0.050→0.024 (0.004) | 0.101→0.024 | 0.063 |

Majority baseline (train-majority `recumbent`): accuracy 0.598, balanced acc 0.333, macro-F1 0.250. Set-truth windows: 8,630; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | classwise ECE | val status | tau | test gate | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|
| recumbent | yes | 38,480 | 0.906 | 0.923 | 0.915 | 0.033 | strong | 0.850 | P=0.962 n=26,548 pass | strong | 0 |
| seated_likely | yes | 31,775 | 0.814 | 0.872 | 0.842 | 0.031 | weak | 0.300 | P=0.814 n=34,029 fail | weak | 0 |
| upright_stationary | yes | 4,220 | 0.471 | 0.140 | 0.215 | 0.007 | abstain | 1.000 | – | abstain | 0 |
| postural_transition | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |

Per dataset:

| dataset | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | per-class F1 |
|---|---|---|---|---|---|---|
| capture24 | 73,985 | 0.639 | 0.650 [0.631, 0.669] | 0.387 | 0.024 | recumbent 0.92 (n=38401), seated_likely 0.84 (n=31548), upright_stationary 0.19 (n=4036) |
| hhar_watch | 74 | 0.568 | 0.657 [0.624, 0.684] | 1.358 | 0.201 | seated_likely 0.83 (n=37), upright_stationary 0.48 (n=37) |
| mhealth | 16 | 0.389 | 0.256 [0.190, 0.317] | 0.958 | 0.422 | recumbent 0.62 (n=4), seated_likely 0.15 (n=6), upright_stationary 0.00 (n=6) |
| opportunity | 37 | 0.643 | 0.684 [0.684, 0.684] | 0.445 | 0.158 | seated_likely 0.92 (n=30), upright_stationary 0.44 (n=7) |
| pamap2 | 204 | 0.738 | 0.746 [0.682, 0.746] | 0.620 | 0.103 | recumbent 0.86 (n=75), seated_likely 0.69 (n=74), upright_stationary 0.69 (n=55) |
| wisdm2019_watch | 159 | 0.660 | 0.719 [0.574, 0.843] | 0.737 | 0.128 | seated_likely 0.70 (n=80), upright_stationary 0.74 (n=79) |

Wrist-only: n=74,475, macro-F1 0.657 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.983, P 0.862; ≥0.6: cov 0.909, P 0.883; ≥0.7: cov 0.819, P 0.904; ≥0.8: cov 0.683, P 0.927; ≥0.9: cov 0.433, P 0.951; ≥0.95: cov 0.220, P 0.965

Confusion (rows truth, cols pred; recumbent, seated_likely, upright_stationary, postural_transition):

```
  35520    2928      32       0
   3449   27697     629       0
    227    3404     589       0
      0       0       0       0
```

### locomotion

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|
| 91,653 | 0.870 | 0.640 [0.595, 0.685] | 0.678 [0.642, 0.706] | 0.569→0.375 | 0.278→0.180 | 0.073→0.022 (0.003) | 0.059→0.010 | 0.025 |

Majority baseline (train-majority `stationary`): accuracy 0.801, balanced acc 0.143, macro-F1 0.127. Set-truth windows: 453; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | classwise ECE | val status | tau | test gate | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|
| stationary | yes | 73,196 | 0.910 | 0.969 | 0.939 | 0.023 | strong | 0.715 | P=0.964 n=68,799 pass | strong | 0 |
| walking | yes | 8,527 | 0.795 | 0.558 | 0.656 | 0.013 | strong | 0.820 | P=0.975 n=3,238 pass | strong | 0 |
| brisk_walking | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |
| running | yes | 203 | 0.911 | 0.852 | 0.880 | 0.001 | strong | 0.695 | P=0.941 n=152 fail | weak | 0 |
| stairs | yes | 152 | 0.718 | 0.737 | 0.727 | 0.002 | weak | 0.445 | P=0.780 n=141 fail | weak | 0 |
| cycling | yes | 808 | 0.717 | 0.627 | 0.669 | 0.002 | weak | 0.300 | P=0.721 n=703 fail | weak | 0 |
| vehicle_motion | yes | 3,518 | 0.711 | 0.383 | 0.498 | 0.021 | weak | 0.530 | P=0.838 n=1,297 fail | weak | 0 |
| other | yes | 5,249 | 0.396 | 0.355 | 0.374 | 0.009 | abstain | 1.000 | – | abstain | 0 |

Per dataset:

| dataset | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | per-class F1 |
|---|---|---|---|---|---|---|
| capture24 | 89,829 | 0.531 | 0.560 [0.452, 0.625] | 0.378 | 0.022 | stationary 0.94 (n=71942), walking 0.65 (n=8375), running 0.78 (n=103), stairs 0.04 (n=8), cycling 0.65 (n=743), vehicle_motion 0.50 (n=3484), other 0.37 (n=5174) |
| hhar_watch | 174 | 0.962 | 0.966 [0.964, 0.970] | 0.187 | 0.099 | stationary 0.99 (n=74), walking 0.96 (n=35), stairs 0.98 (n=32), cycling 0.94 (n=33) |
| mhealth | 49 | 0.807 | 0.750 [0.728, 0.949] | 0.270 | 0.056 | stationary 0.91 (n=19), walking 0.73 (n=4), running 1.00 (n=10), stairs 0.00 (n=3), cycling 1.00 (n=4), other 0.86 (n=9) |
| opportunity | 37 | 0.919 | 0.958 [0.958, 0.958] | 0.287 | 0.201 | stationary 0.96 (n=37) |
| pamap2 | 397 | 0.763 | 0.757 [0.757, 0.791] | 0.481 | 0.063 | stationary 0.86 (n=187), walking 0.82 (n=43), running 1.00 (n=10), stairs 0.73 (n=29), cycling 0.94 (n=28), vehicle_motion 0.15 (n=34), other 0.78 (n=66) |
| wisdm2019_watch | 1,167 | 0.920 | 0.928 [0.884, 0.959] | 0.166 | 0.078 | stationary 0.99 (n=937), walking 0.86 (n=70), running 0.98 (n=80), stairs 0.87 (n=80) |

Wrist-only: n=91,653, macro-F1 0.678 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.911, P 0.915; ≥0.6: cov 0.860, P 0.940; ≥0.7: cov 0.815, P 0.959; ≥0.8: cov 0.766, P 0.973; ≥0.9: cov 0.668, P 0.984; ≥0.95: cov 0.505, P 0.990

Confusion (rows truth, cols pred; stationary, walking, brisk_walking, running, stairs, cycling, vehicle_motion, other):

```
  70958     665       0       5       1      51     349    1167
   2093    4757       0       3      22      81      91    1480
      0       0       0       0       0       0       0       0
      4      26       0     173       0       0       0       0
      3      29       0       0     112       0       0       8
    221      35       0       0       0     507       5      40
   1930      79       0       0       1      12    1349     147
   2808     392       0       9      20      56     102    1862
```

### arm_behavior

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|
| 20,972 | 0.653 | 0.471 [0.427, 0.566] | 0.416 [0.372, 0.462] | 0.908→0.665 | 0.574→0.441 | 0.094→0.066 (0.009) | 0.178→0.053 | 0.219 |

Majority baseline (train-majority `desk_like`): accuracy 0.646, balanced acc 0.333, macro-F1 0.262. Set-truth windows: 0; windows whose truth is an unsupported class (not scored): 14.

| class | supported | test support | P | R | F1 | classwise ECE | val status | tau | test gate | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|
| quiet | yes | 6,845 | 0.077 | 0.000 | 0.000 | 0.079 | abstain | 1.000 | – | abstain | 0 |
| desk_like | yes | 13,545 | 0.657 | 0.993 | 0.790 | 0.066 | weak | 0.720 | P=0.774 n=10,661 fail | weak | 0 |
| fidgeting | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |
| repetitive_hand_motion | yes | 582 | 0.505 | 0.419 | 0.458 | 0.013 | strong | 0.690 | P=0.766 n=124 fail | weak | 0 |
| active_gesturing | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |
| exercise_motion | no | 0 | – | – | – | – | unsupported | – | – | – | 14 |
| other | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |

Per dataset:

| dataset | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | per-class F1 |
|---|---|---|---|---|---|---|
| capture24 | 20,580 | 0.422 | 0.361 [0.267, 0.405] | 0.665 | 0.066 | quiet 0.00 (n=6802), desk_like 0.79 (n=13385), repetitive_hand_motion 0.29 (n=393) |
| mhealth | 12 | 0.000 | 0.000 [0.000, 0.000] | 1.511 | 0.778 | quiet 0.00 (n=12) |
| pamap2 | 60 | 0.397 | 0.442 [0.423, 0.462] | 1.008 | 0.339 | quiet 0.00 (n=31), repetitive_hand_motion 0.88 (n=29) |
| wisdm2019_watch | 320 | 0.853 | 0.850 [0.678, 0.969] | 0.565 | 0.111 | desk_like 0.87 (n=160), repetitive_hand_motion 0.83 (n=160) |

Wrist-only: n=20,972, macro-F1 0.416 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.958, P 0.664; ≥0.6: cov 0.836, P 0.680; ≥0.7: cov 0.564, P 0.756; ≥0.8: cov 0.300, P 0.843; ≥0.9: cov 0.021, P 0.924; ≥0.95: cov 0.000, P –

Confusion (rows truth, cols pred; quiet, desk_like, fidgeting, repetitive_hand_motion, active_gesturing, exercise_motion, other):

```
      1    6696       0     148       0       0       0
      9   13445       0      91       0       0       0
      0       0       0       0       0       0       0
      3     335       0     244       0       0       0
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
