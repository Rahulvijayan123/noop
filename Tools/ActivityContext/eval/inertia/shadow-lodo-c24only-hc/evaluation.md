# Evaluation — `shadow-lodo-c24only-hc` (lodo)

> **STAND-IN ENCODERS — NOT INERTIA-1; real Inertia-1 evaluation blocked: no public checkpoint.** Every number below is a *measured* result for a stand-in encoder on public wrist data; nothing here is evidence about Inertia-1 itself.

- bundle_sha256 `c0d3529c78c7e979d45f12c9e9a598b5801e50e6b5d8b359ad70ec236e338162`; encoder `standin:handcrafted-stats-v1` (standin); evidence_tier_max `shadow`
- evaluated once on the frozen test subjects through `load_bundle(...).apply(...)`; test_sha256 `6afd705530ea8f98e32f7c40997c4db53952ebdcd411fea823493c71a8311898`; evaluations of this experiment: 2 (rerun reason: run-1 bundle directory was deleted by an external process (~19:55, /tmp); bundle retrained deterministically from identical code/data/splits; no model, rule or threshold changed); bundle.apply vs training-side numpy max |Δ| (first 2,000 windows) 0.000000000000
- test windows: capture24 96,819 (50 subj), hhar_watch 1,998 (2 subj), mhealth 49 (2 subj), opportunity 2,539 (1 subj), pamap2 5,167 (2 subj), wisdm2019_watch 1,397 (8 subj)
- nonfinite windows dropped: 0

### posture

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|
| 74,475 | 0.876 | 0.681 [0.661, 0.700] | 0.701 [0.675, 0.724] | 0.418→0.325 | 0.235→0.182 | 0.045→0.007 (0.004) | 0.076→0.012 | 0.039 |

Majority baseline (train-majority `recumbent`): accuracy 0.598, balanced acc 0.333, macro-F1 0.250. Set-truth windows: 8,630; windows whose truth is an unsupported class (not scored): 0.

| class | supported | test support | P | R | F1 | classwise ECE | val status | tau | test gate | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|
| recumbent | yes | 37,878 | 0.937 | 0.922 | 0.929 | 0.015 | strong | 0.685 | P=0.959 n=34,841 pass | strong | 0 |
| seated_likely | yes | 32,377 | 0.829 | 0.909 | 0.867 | 0.016 | weak | 0.300 | P=0.829 n=35,531 fail | weak | 0 |
| upright_stationary | yes | 4,220 | 0.543 | 0.212 | 0.305 | 0.005 | abstain | 1.000 | – | abstain | 0 |
| postural_transition | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |

Per dataset:

| dataset | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | per-class F1 |
|---|---|---|---|---|---|---|
| capture24 | 73,985 | 0.684 | 0.704 [0.680, 0.727] | 0.319 | 0.009 | recumbent 0.93 (n=37807), seated_likely 0.87 (n=32142), upright_stationary 0.31 (n=4036) |
| hhar_watch | 74 | 0.311 | 0.287 [0.161, 0.367] | 2.342 | 0.426 | seated_likely 0.57 (n=37), upright_stationary 0.00 (n=37) |
| mhealth | 16 | 0.500 | 0.383 [0.222, 0.517] | 1.187 | 0.262 | recumbent 0.44 (n=4), seated_likely 0.71 (n=6), upright_stationary 0.00 (n=6) |
| opportunity | 37 | 0.610 | 0.626 [0.626, 0.626] | 0.497 | 0.099 | seated_likely 0.89 (n=30), upright_stationary 0.36 (n=7) |
| pamap2 | 204 | 0.536 | 0.502 [0.317, 0.527] | 0.939 | 0.268 | recumbent 0.79 (n=67), seated_likely 0.63 (n=82), upright_stationary 0.09 (n=55) |
| wisdm2019_watch | 159 | 0.413 | 0.354 [0.254, 0.419] | 1.246 | 0.341 | seated_likely 0.59 (n=80), upright_stationary 0.12 (n=79) |

Wrist-only: n=74,475, macro-F1 0.701 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.990, P 0.879; ≥0.6: cov 0.922, P 0.900; ≥0.7: cov 0.846, P 0.920; ≥0.8: cov 0.746, P 0.941; ≥0.9: cov 0.582, P 0.965; ≥0.95: cov 0.418, P 0.979

Confusion (rows truth, cols pred; recumbent, seated_likely, upright_stationary, postural_transition):

```
  34927    2925      26       0
   2207   29442     728       0
    160    3164     896       0
      0       0       0       0
```

### locomotion

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|
| 91,298 | 0.873 | 0.627 [0.590, 0.655] | 0.650 [0.614, 0.675] | 0.551→0.355 | 0.264→0.172 | 0.091→0.015 (0.003) | 0.085→0.014 | 0.022 |

Majority baseline (train-majority `stationary`): accuracy 0.804, balanced acc 0.200, macro-F1 0.178. Set-truth windows: 453; windows whose truth is an unsupported class (not scored): 355.

| class | supported | test support | P | R | F1 | classwise ECE | val status | tau | test gate | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|
| stationary | yes | 73,149 | 0.931 | 0.956 | 0.943 | 0.024 | strong | 0.635 | P=0.967 n=69,365 pass | strong | 0 |
| walking | yes | 8,574 | 0.755 | 0.610 | 0.675 | 0.009 | strong | 0.905 | P=0.979 n=3,143 pass | strong | 0 |
| brisk_walking | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |
| running | no | 0 | – | – | – | – | unsupported | – | – | – | 203 |
| stairs | no | 0 | – | – | – | – | unsupported | – | – | – | 152 |
| cycling | yes | 808 | 0.678 | 0.627 | 0.652 | 0.002 | weak | 0.300 | P=0.682 n=740 fail | weak | 0 |
| vehicle_motion | yes | 3,518 | 0.643 | 0.498 | 0.561 | 0.025 | weak | 0.500 | P=0.783 n=1,887 fail | weak | 0 |
| other | yes | 5,249 | 0.397 | 0.443 | 0.419 | 0.009 | abstain | 1.000 | – | abstain | 0 |

Per dataset:

| dataset | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | per-class F1 |
|---|---|---|---|---|---|---|
| capture24 | 89,718 | 0.628 | 0.662 [0.623, 0.694] | 0.344 | 0.015 | stationary 0.95 (n=71895), walking 0.67 (n=8422), cycling 0.69 (n=743), vehicle_motion 0.57 (n=3484), other 0.43 (n=5174) |
| hhar_watch | 142 | 0.838 | 0.850 [0.781, 0.909] | 0.330 | 0.065 | stationary 0.96 (n=74), walking 0.91 (n=35), cycling 0.68 (n=33) |
| mhealth | 36 | 0.711 | 0.579 [0.556, 0.610] | 0.759 | 0.228 | stationary 0.91 (n=19), walking 0.40 (n=4), cycling 1.00 (n=4), other 0.00 (n=9) |
| opportunity | 37 | 0.432 | 0.604 [0.604, 0.604] | 1.172 | 0.126 | stationary 0.60 (n=37) |
| pamap2 | 358 | 0.687 | 0.663 [0.663, 0.701] | 0.646 | 0.051 | stationary 0.86 (n=187), walking 0.63 (n=43), cycling 0.70 (n=28), vehicle_motion 0.56 (n=34), other 0.56 (n=66) |
| wisdm2019_watch | 1,007 | 0.764 | 0.740 [0.625, 0.836] | 1.148 | 0.121 | stationary 0.70 (n=937), walking 0.78 (n=70) |

Wrist-only: n=91,298, macro-F1 0.650 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 0.898, P 0.926; ≥0.6: cov 0.849, P 0.951; ≥0.7: cov 0.810, P 0.967; ≥0.8: cov 0.771, P 0.977; ≥0.9: cov 0.708, P 0.986; ≥0.95: cov 0.604, P 0.991

Confusion (rows truth, cols pred; stationary, walking, brisk_walking, running, stairs, cycling, vehicle_motion, other):

```
  69905     889       0       0       0     117     546    1692
   1591    5228       0       0       0      88     169    1498
      0       0       0       0       0       0       0       0
      0       0       0       0       0       0       0       0
      0       0       0       0       0       0       0       0
     65      73       0       0       0     507      65      98
   1434      96       0       0       0       1    1751     236
   2059     640       0       0       0      35     192    2323
```

### arm_behavior

| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |
|---|---|---|---|---|---|---|---|---|
| 20,390 | 0.664 | 0.500 [0.500, 0.500] | 0.399 [0.368, 0.428] | 0.671→0.643 | 0.470→0.450 | 0.060→0.142 (0.007) | 0.167→0.142 | 0.202 |

Majority baseline (train-majority `desk_like`): accuracy 0.664, balanced acc 0.500, macro-F1 0.399. Set-truth windows: 0; windows whose truth is an unsupported class (not scored): 596.

| class | supported | test support | P | R | F1 | classwise ECE | val status | tau | test gate | final status | unsupported-truth windows |
|---|---|---|---|---|---|---|---|---|---|---|---|
| quiet | yes | 6,845 | 0.000 | 0.000 | 0.000 | 0.142 | abstain | 1.000 | – | abstain | 0 |
| desk_like | yes | 13,545 | 0.664 | 1.000 | 0.798 | 0.142 | weak | 0.735 | P=0.851 n=6,999 fail | weak | 0 |
| fidgeting | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |
| repetitive_hand_motion | no | 0 | – | – | – | – | unsupported | – | – | – | 582 |
| active_gesturing | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |
| exercise_motion | no | 0 | – | – | – | – | unsupported | – | – | – | 14 |
| other | no | 0 | – | – | – | – | unsupported | – | – | – | 0 |

Per dataset:

| dataset | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | per-class F1 |
|---|---|---|---|---|---|---|
| capture24 | 20,187 | 0.500 | 0.399 [0.367, 0.427] | 0.644 | 0.142 | quiet 0.00 (n=6802), desk_like 0.80 (n=13385) |
| mhealth | 12 | 0.000 | 0.000 [0.000, 0.000] | 1.320 | 0.733 | quiet 0.00 (n=12) |
| pamap2 | 31 | 0.000 | 0.000 [0.000, 0.000] | 1.299 | 0.727 | quiet 0.00 (n=31) |
| wisdm2019_watch | 160 | 1.000 | 1.000 [1.000, 1.000] | 0.305 | 0.263 | desk_like 1.00 (n=160) |

Wrist-only: n=20,390, macro-F1 0.399 (every training/test placement is wrist or forearm; equals pooled).

Coverage / precision at fixed confidence thresholds (top-label): ≥0.5: cov 1.000, P 0.664; ≥0.6: cov 1.000, P 0.664; ≥0.7: cov 0.999, P 0.665; ≥0.8: cov 0.000, P –; ≥0.9: cov 0.000, P –; ≥0.95: cov 0.000, P –

Confusion (rows truth, cols pred; quiet, desk_like, fidgeting, repetitive_hand_motion, active_gesturing, exercise_motion, other):

```
      0    6845       0       0       0       0       0
      0   13545       0       0       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
      0       0       0       0       0       0       0
```

### transition (multi-label events)

| event | supported | n (pos) | AUROC | AP | Brier raw→cal | ECE raw→cal | val→final status |
|---|---|---|---|---|---|---|---|
| sit_to_stand_like | yes | 75,222 (385) | 0.940 | 0.056 | 0.071→0.069 | 0.167→0.131 | abstain→abstain |
| stand_to_sit_like | yes | 75,222 (518) | 0.911 | 0.055 | 0.087→0.088 | 0.187→0.161 | abstain→abstain |
| lying_down_like | no | – (0) | – | – | – | – | unsupported |
| getting_up_like | no | – (11) | – | – | – | – | unsupported |
| walk_start | yes | 75,222 (492) | 0.950 | 0.079 | 0.063→0.060 | 0.151→0.114 | abstain→abstain |
| walk_stop | yes | 75,222 (650) | 0.916 | 0.074 | 0.087→0.087 | 0.198→0.156 | abstain→abstain |
| run_start | no | – (4) | – | – | – | – | unsupported |
| run_stop | no | – (0) | – | – | – | – | unsupported |

Event-level (Opportunity/PAMAP2/HHAR dense 2-s windows; theta chosen on val):

| event | theta (val status) | true events | P/R/F1 ±5 s | P/R/F1 ±10 s | median / p90 abs error (s, ±10 s) |
|---|---|---|---|---|---|
| sit_to_stand_like | 0.70 (weak) | 36 | 0.02/0.25/0.04 | 0.04/0.47/0.07 | 4.9 / 8.3 |
| stand_to_sit_like | 0.60 (weak) | 36 | 0.02/0.33/0.05 | 0.05/0.69/0.10 | 5.1 / 8.9 |
| walk_start | 0.25 (weak) | 405 | 0.28/0.36/0.32 | 0.35/0.45/0.39 | 2.4 / 6.7 |
| walk_stop | 0.40 (weak) | 404 | 0.24/0.38/0.30 | 0.31/0.48/0.37 | 2.4 / 7.2 |

event-level timing only where ground truth supports it (Opportunity, PAMAP2, HHAR dense 2-s windows); Capture-24 supports event presence only (per-window AUROC/AP above)

### movement_intensity

Target clip(ln(MET)/ln(12),0,1) from Capture-24 annotation METs / PAMAP2 protocol METs; split-conformal 80% half-width 0.142.

| set | n | MAE | MAE const (test mean) | R² | Spearman | 80% interval coverage |
|---|---|---|---|---|---|---|
| pooled | 95,813 | 0.103 | 0.136 | 0.501 | 0.758 | 0.786 |
| capture24 | 95,579 | 0.102 | 0.136 | 0.499 | 0.757 | 0.786 |
| pamap2 | 234 | 0.132 | 0.203 | 0.487 | 0.813 | 0.692 |

## OOD

Bundle method `maha_global` (k=None), threshold 14.247 (0.95 quantile of VAL ID scores); ID test false-alarm rate 0.057 on 97,403 windows.


Measured: every table above (test subjects, once). Inferred: nothing about Inertia-1 or WHOOP straps — the encoders are stand-ins and the data are public wrist datasets.
